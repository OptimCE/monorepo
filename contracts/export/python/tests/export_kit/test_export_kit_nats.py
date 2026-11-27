"""The consumer on a real JetStream (copied with core/export).

The annexes' CI has no broker, so these run only when EXPORT_KIT_NATS_URL points at one
(``nats-server -js``); they declare the EXPORTS stream themselves, like crm-backend does.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import uuid
from collections.abc import AsyncIterator
from typing import Any

import pytest

from core.export import MemoryPartStore, PartContext, part_prefix, request_subject
from core.export.consumer import ensure_service_consumer, run_export_consumer

NATS_URL = os.environ.get("EXPORT_KIT_NATS_URL")
pytestmark = pytest.mark.skipif(not NATS_URL, reason="EXPORT_KIT_NATS_URL is not set")
SERVICE = "kit-py"


@pytest.fixture
async def js() -> AsyncIterator[Any]:
    import nats
    from nats.js.api import RetentionPolicy, StorageType, StreamConfig

    assert NATS_URL
    nc = await nats.connect(NATS_URL)
    jsx = nc.jetstream()
    with contextlib.suppress(Exception):
        await jsx.delete_stream("EXPORTS")
    await jsx.add_stream(
        StreamConfig(
            name="EXPORTS",
            subjects=["export.>"],
            retention=RetentionPolicy.WORK_QUEUE,
            storage=StorageType.FILE,
            duplicate_window=120,
        )
    )
    yield jsx
    with contextlib.suppress(Exception):
        await jsx.delete_stream("EXPORTS")
    await nc.drain()


def make_request(**overrides: Any) -> dict[str, Any]:
    export_id = str(uuid.uuid4())
    request = {
        "schemaVersion": "1.0",
        "exportId": export_id,
        "partId": str(uuid.uuid4()),
        "service": SERVICE,
        "attempt": 1,
        "scope": {"type": "community", "id": "2"},
        "requester": {"userId": "auth0|admin"},
        "requestedAt": "2026-11-15T10:00:00Z",
        "storage": {"bucket": "exports", "prefix": part_prefix(export_id, SERVICE)},
    }
    request.update(overrides)
    return request


async def publish(js: Any, request: dict[str, Any], msg_id: str | None = None) -> None:
    await js.publish(
        request_subject(SERVICE),
        json.dumps(request).encode(),
        headers={"Nats-Msg-Id": msg_id or f"{request['partId']}:{request['attempt']}"},
    )


async def answers(js: Any, count: int) -> list[tuple[str, dict[str, Any]]]:
    from nats.js.api import AckPolicy, ConsumerConfig

    name = f"answers-{uuid.uuid4().hex[:8]}"
    await js.add_consumer(
        "EXPORTS",
        ConsumerConfig(
            durable_name=name,
            ack_policy=AckPolicy.EXPLICIT,
            filter_subjects=["export.part.done", "export.part.failed"],
        ),
    )
    sub = await js.pull_subscribe_bind(durable=name, stream="EXPORTS")
    out: list[tuple[str, dict[str, Any]]] = []
    while len(out) < count:
        for msg in await sub.fetch(1, timeout=10):
            out.append((msg.subject, json.loads(msg.data)))
            await msg.ack()
    await sub.unsubscribe()
    await js.delete_consumer("EXPORTS", name)
    return out


@contextlib.asynccontextmanager
async def consumer(js: Any, handler, **kwargs: Any) -> AsyncIterator[list[Any]]:
    outcomes: list[Any] = []
    stop = asyncio.Event()
    task = asyncio.create_task(
        run_export_consumer(
            js,
            service=SERVICE,
            handler=handler,
            store=kwargs.pop("store", MemoryPartStore()),
            stop=stop,
            pull_timeout=1.0,
            retry=0.2,
            nak_delays=(0.1, 0.1, 0.1, 0.1),
            on_outcome=outcomes.append,
            **kwargs,
        )
    )
    try:
        yield outcomes
    finally:
        stop.set()
        await asyncio.wait_for(task, timeout=15)


async def wait_until(predicate, within: float = 10.0) -> None:
    async with asyncio.timeout(within):
        while not predicate():  # noqa: ASYNC110  # polls a test-only list, no event to wait on
            await asyncio.sleep(0.05)


async def test_a_request_is_answered_done_and_acked(js: Any) -> None:
    store = MemoryPartStore()

    async def handler(ctx: PartContext) -> None:
        await ctx.write_json("items", [{"a": 1}])

    async with consumer(js, handler, store=store) as outcomes:
        request = make_request()
        await publish(js, request)
        [(subject, body)] = await answers(js, 1)
        await wait_until(lambda: len(outcomes) == 1)
    assert subject == "export.part.done"
    assert body["files"][0]["path"] == f"{SERVICE}/items.json"
    info = await js.consumer_info("EXPORTS", f"export-{SERVICE}")
    assert (info.num_ack_pending, info.num_pending) == (0, 0)


async def test_a_transient_error_is_redelivered(js: Any) -> None:
    calls = 0

    async def handler(ctx: PartContext) -> None:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise ConnectionResetError("database restarting")

    async with consumer(js, handler):
        await publish(js, make_request())
        [(subject, _)] = await answers(js, 1)
    assert (subject, calls) == ("export.part.done", 2)


async def test_the_last_allowed_delivery_answers_failed(js: Any) -> None:
    calls = 0

    async def handler(ctx: PartContext) -> None:
        nonlocal calls
        calls += 1
        raise RuntimeError("always broken")

    async with consumer(js, handler, max_deliver=3):
        await publish(js, make_request())
        [(subject, body)] = await answers(js, 1)
    assert (subject, body["errorCode"], calls) == ("export.part.failed", "internal", 3)


async def test_delivered_twice_it_writes_once(js: Any) -> None:
    store = MemoryPartStore()
    runs = 0

    async def handler(ctx: PartContext) -> None:
        nonlocal runs
        runs += 1
        await ctx.write_json("items", [{"run": runs}])

    async with consumer(js, handler, store=store) as outcomes:
        request = make_request()
        await publish(js, request, "first")
        await publish(js, request, "second")
        await wait_until(lambda: len(outcomes) == 2)
    assert [o.replayed for o in outcomes] == [False, True]
    assert runs == 1
    assert len(await answers(js, 1)) == 1


async def test_one_part_in_flight_at_a_time(js: Any) -> None:
    gate = asyncio.Event()
    in_flight = 0
    peak = 0

    async def handler(ctx: PartContext) -> None:
        nonlocal in_flight, peak
        in_flight += 1
        peak = max(peak, in_flight)
        await gate.wait()
        in_flight -= 1

    async with consumer(js, handler):
        await publish(js, make_request())
        await publish(js, make_request())
        await wait_until(lambda: in_flight == 1)
        info = await js.consumer_info("EXPORTS", f"export-{SERVICE}")
        assert (info.num_ack_pending, info.num_pending) == (1, 1)
        gate.set()
        await answers(js, 2)
    assert peak == 1


async def test_a_shutdown_naks_and_the_next_instance_finishes(js: Any) -> None:
    started = asyncio.Event()

    async def slow(ctx: PartContext) -> None:
        started.set()
        while True:
            ctx.checkpoint()
            await asyncio.sleep(0.02)

    async with consumer(js, slow) as outcomes:
        await publish(js, make_request())
        await asyncio.wait_for(started.wait(), timeout=10)
    assert [o.kind for o in outcomes] == ["aborted"]

    async def quick(ctx: PartContext) -> None:
        return None

    async with consumer(js, quick):
        [(subject, _)] = await answers(js, 1)
    assert subject == "export.part.done"


async def test_an_existing_durable_is_brought_back_to_the_declared_settings(
    js: Any,
) -> None:
    from nats.js.api import AckPolicy, ConsumerConfig

    await js.add_consumer(
        "EXPORTS",
        ConsumerConfig(
            durable_name=f"export-{SERVICE}",
            ack_policy=AckPolicy.EXPLICIT,
            filter_subject=request_subject(SERVICE),
            ack_wait=5,
            max_deliver=20,
            max_ack_pending=10,
        ),
    )
    await ensure_service_consumer(js, SERVICE)
    config = (await js.consumer_info("EXPORTS", f"export-{SERVICE}")).config
    assert (config.ack_wait, config.max_deliver, config.max_ack_pending) == (60, 5, 1)
