"""The service's export listener: a durable pull consumer on export.request.<service>.

Started with the service (inside its API process, next to the HTTP routes), it handles one part
at a time and survives the EXPORTS stream not existing yet (crm-backend declares it) and broker
hiccups. Stop it by setting ``stop``: a part in progress is nak'ed for immediate redelivery.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from collections.abc import Callable
from typing import Any

from nats.errors import TimeoutError as NatsTimeoutError
from nats.js.api import AckPolicy, ConsumerConfig, DeliverPolicy
from nats.js.client import JetStreamContext
from nats.js.errors import NotFoundError

from .contract import (
    EXPORT_ACK_WAIT_SECONDS,
    EXPORT_MAX_DELIVER,
    EXPORT_NAK_DELAYS_SECONDS,
    EXPORTS_STREAM,
    request_subject,
    service_durable,
)
from .runner import ExportHandler, PartOutcome, handle_part
from .store import PartStore

logger = logging.getLogger(__name__)

_STREAM_NOT_FOUND = 10059
_CONSUMER_NOT_FOUND = 10014


class NatsPartPublisher:
    def __init__(self, js: JetStreamContext) -> None:
        self._js = js

    async def publish(self, subject: str, payload: dict[str, Any], msg_id: str) -> None:
        await self._js.publish(
            subject,
            json.dumps(payload).encode("utf-8"),
            stream=EXPORTS_STREAM,
            headers={"Nats-Msg-Id": msg_id},
        )


async def ensure_service_consumer(
    js: JetStreamContext,
    service: str,
    *,
    ack_wait: float = EXPORT_ACK_WAIT_SECONDS,
    max_deliver: int = EXPORT_MAX_DELIVER,
) -> None:
    """Creates the durable, or brings an existing one back to the declared settings.

    nats-py never reconciles an existing durable by itself. Raises NotFoundError (err_code
    10059) while the EXPORTS stream does not exist.
    """
    durable = service_durable(service)
    declared: dict[str, Any] = {
        "filter_subject": request_subject(service),
        "ack_wait": ack_wait,
        "max_deliver": max_deliver,
        "max_ack_pending": 1,
    }
    try:
        info = await js.consumer_info(EXPORTS_STREAM, durable)
    except NotFoundError as err:
        if err.err_code != _CONSUMER_NOT_FOUND:
            raise
        await js.add_consumer(
            EXPORTS_STREAM,
            ConsumerConfig(
                durable_name=durable,
                ack_policy=AckPolicy.EXPLICIT,
                deliver_policy=DeliverPolicy.ALL,
                **declared,
            ),
        )
        return
    current = info.config
    drift = {k: v for k, v in declared.items() if getattr(current, k) != v}
    if drift:
        await js.add_consumer(EXPORTS_STREAM, config=current.evolve(**drift))


async def run_export_consumer(
    js: JetStreamContext,
    *,
    service: str,
    handler: ExportHandler,
    store: PartStore,
    stop: asyncio.Event,
    expected_bucket: str | None = None,
    ack_wait: float = EXPORT_ACK_WAIT_SECONDS,
    heartbeat: float | None = None,
    max_deliver: int = EXPORT_MAX_DELIVER,
    nak_delays: tuple[float, ...] = EXPORT_NAK_DELAYS_SECONDS,
    pull_timeout: float = 5.0,
    retry: float = 15.0,
    on_outcome: Callable[[PartOutcome], None] | None = None,
) -> None:
    """Runs until ``stop`` is set."""
    durable = service_durable(service)
    beat = heartbeat if heartbeat is not None else ack_wait / 3
    ids = {"service": service, "durable": durable}

    while not stop.is_set():
        try:
            await ensure_service_consumer(js, service, ack_wait=ack_wait, max_deliver=max_deliver)
            break
        except Exception as err:
            missing = isinstance(err, NotFoundError) and err.err_code == _STREAM_NOT_FOUND
            logger.warning(
                "EXPORTS stream not declared yet; retrying"
                if missing
                else "Export consumer setup failed; retrying",
                extra={**ids, "retry_seconds": retry},
            )
            await _sleep(retry, stop)
    if stop.is_set():
        return

    subscription = await js.pull_subscribe_bind(durable=durable, stream=EXPORTS_STREAM)
    publisher = NatsPartPublisher(js)
    logger.info("Export consumer ready", extra=ids)
    try:
        while not stop.is_set():
            try:
                messages = await subscription.fetch(1, timeout=pull_timeout)
            except NatsTimeoutError:
                continue
            except Exception as err:
                logger.warning(
                    "Export pull failed; retrying",
                    extra={**ids, "error": type(err).__name__},
                )
                await _sleep(min(retry, 5.0), stop)
                continue
            for msg in messages:
                if stop.is_set():
                    await msg.nak()
                    break
                await _process(
                    msg,
                    service=service,
                    handler=handler,
                    store=store,
                    publisher=publisher,
                    stop=stop,
                    expected_bucket=expected_bucket,
                    max_deliver=max_deliver,
                    nak_delays=nak_delays,
                    beat=beat,
                    on_outcome=on_outcome,
                )
    finally:
        with contextlib.suppress(Exception):
            await subscription.unsubscribe()


async def _process(
    msg: Any,
    *,
    service: str,
    handler: ExportHandler,
    store: PartStore,
    publisher: NatsPartPublisher,
    stop: asyncio.Event,
    expected_bucket: str | None,
    max_deliver: int,
    nak_delays: tuple[float, ...],
    beat: float,
    on_outcome: Callable[[PartOutcome], None] | None,
) -> None:
    async def keep_alive() -> None:
        while True:
            await asyncio.sleep(beat)
            with contextlib.suppress(Exception):
                await msg.in_progress()

    alive = asyncio.create_task(keep_alive())
    try:
        outcome = await handle_part(
            msg.data,
            service=service,
            handler=handler,
            store=store,
            publisher=publisher,
            delivery_count=int(msg.metadata.num_delivered),
            max_deliver=max_deliver,
            nak_delays=nak_delays,
            expected_bucket=expected_bucket,
            stop=stop,
        )
    finally:
        alive.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await alive

    if outcome.kind in ("done", "failed"):
        await msg.ack_sync()
    elif outcome.kind == "retry":
        await msg.nak(delay=outcome.delay)
    elif outcome.kind == "aborted":
        await msg.nak()
    else:
        logger.error(
            "Unanswerable export request terminated",
            extra={
                "service": service,
                "stream_seq": msg.metadata.sequence.stream,
                "reason": outcome.reason,
            },
        )
        await msg.term()
    if on_outcome is not None:
        on_outcome(outcome)


async def _sleep(seconds: float, stop: asyncio.Event) -> None:
    with contextlib.suppress(TimeoutError):
        await asyncio.wait_for(stop.wait(), timeout=seconds)
