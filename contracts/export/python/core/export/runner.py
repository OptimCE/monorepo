"""handle_part: one export.request.<service> message, NATS-free.

Parse, check, replay or empty the prefix, run the handler, answer done or failed. The consumer
turns the outcome into ack / nak / term; the contract check runs exactly this function.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from collections.abc import AsyncIterator, Awaitable, Callable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any, Literal, Protocol

from .context import PartContext, iso_utc
from .contract import (
    EXPORT_MAX_DELIVER,
    EXPORT_NAK_DELAYS_SECONDS,
    EXPORT_PART_DONE_SUBJECT,
    EXPORT_PART_FAILED_SUBJECT,
    EXPORT_SCHEMA_MAJOR,
    EXPORT_SCHEMA_VERSION,
    PART_DONE_MARKER,
    PartDone,
    PartErrorCode,
    PartFailed,
    msg_id_for_response,
    part_prefix,
    schema_major,
)
from .errors import ExportAbortedError, ExportPartError, describe_unexpected
from .store import PartStore
from .validation import check_against

logger = logging.getLogger(__name__)

ExportHandler = Callable[[PartContext], Awaitable[None]]


async def empty_handler(ctx: PartContext) -> None:
    """A service with nothing to export answers done with an empty part."""


class PartPublisher(Protocol):
    async def publish(self, subject: str, payload: dict[str, Any], msg_id: str) -> None: ...


OutcomeKind = Literal["done", "failed", "retry", "aborted", "invalid"]


@dataclass(frozen=True)
class PartOutcome:
    """done/failed: answered, ack. retry: nak after ``delay``. aborted: nak now. invalid: term."""

    kind: OutcomeKind
    message: dict[str, Any] = field(default_factory=dict)
    delay: float = 0.0
    reason: str = ""
    # done only: the part was already complete for this attempt; its answer was published again.
    replayed: bool = False


_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_SERVICE = re.compile(r"^[a-z][a-z0-9-]{1,62}$")


@dataclass(frozen=True)
class _Ids:
    export_id: str
    part_id: str
    service: str
    attempt: int

    def log(self) -> dict[str, Any]:
        return {
            "export_id": self.export_id,
            "part_id": self.part_id,
            "service": self.service,
            "attempt": self.attempt,
        }


def _read_ids(value: object) -> _Ids | None:
    """The ids needed to answer at all, read without trusting the rest of the message."""
    if not isinstance(value, dict):
        return None
    export_id, part_id = value.get("exportId"), value.get("partId")
    service, attempt = value.get("service"), value.get("attempt")
    if not (isinstance(export_id, str) and _UUID.match(export_id)):
        return None
    if not (isinstance(part_id, str) and _UUID.match(part_id)):
        return None
    if not (isinstance(service, str) and _SERVICE.match(service)):
        return None
    if isinstance(attempt, bool) or not isinstance(attempt, int) or not 1 <= attempt <= 10:
        return None
    return _Ids(export_id, part_id, service, attempt)


def nak_delay(delays: Sequence[float], delivery_count: int) -> float:
    index = min(max(delivery_count, 1), len(delays)) - 1
    return delays[index] if delays else 0.0


async def handle_part(
    data: bytes | str,
    *,
    service: str,
    handler: ExportHandler,
    store: PartStore,
    publisher: PartPublisher,
    delivery_count: int,
    max_deliver: int = EXPORT_MAX_DELIVER,
    nak_delays: Sequence[float] = EXPORT_NAK_DELAYS_SECONDS,
    expected_bucket: str | None = None,
    stop: asyncio.Event | None = None,
    now: Callable[[], datetime] | None = None,
) -> PartOutcome:
    clock = now or (lambda: datetime.now(UTC))
    stop = stop or asyncio.Event()

    try:
        parsed = json.loads(data)
    except (ValueError, TypeError):
        return PartOutcome("invalid", reason="not JSON")
    ids = _read_ids(parsed)
    if ids is None:
        return PartOutcome("invalid", reason="no usable exportId/partId/service/attempt")

    def retry(reason: str) -> PartOutcome:
        return PartOutcome("retry", delay=nak_delay(nak_delays, delivery_count), reason=reason)

    async def fail(code: PartErrorCode, detail: str) -> PartOutcome:
        message: PartFailed = {
            "schemaVersion": EXPORT_SCHEMA_VERSION,
            "exportId": ids.export_id,
            "partId": ids.part_id,
            "service": ids.service,
            "attempt": ids.attempt,
            "errorCode": code,
            "errorDetail": detail[:2000],
            "failedAt": iso_utc(clock()),
        }
        try:
            await publisher.publish(
                EXPORT_PART_FAILED_SUBJECT,
                message,
                msg_id_for_response(ids.part_id, ids.attempt, "failed"),
            )
        except Exception as err:
            return retry(f"publish failed: {describe_unexpected(err)}")
        logger.warning("Export part failed", extra={**ids.log(), "error_code": code})
        return PartOutcome("failed", message=message)

    major = schema_major(parsed.get("schemaVersion"))
    if major != EXPORT_SCHEMA_MAJOR:
        return await fail("unsupported_schema", f"schemaVersion major {major or 'unreadable'}")
    check = check_against("export-request", parsed)
    if not check.valid:
        return await fail(
            "internal",
            f"request does not match export-request: {'; '.join(check.errors)}",
        )
    request: dict[str, Any] = parsed
    if request["service"] != service:
        return await fail("internal", f"request for {request['service']} delivered to {service}")
    prefix = part_prefix(request["exportId"], request["service"])
    if request["storage"]["prefix"] != prefix:
        return await fail("internal", f"storage.prefix is not {prefix}")
    if expected_bucket and request["storage"]["bucket"] != expected_bucket:
        return await fail("internal", f"storage.bucket is not {expected_bucket}")

    async def publish_done(done: PartDone, replayed: bool) -> PartOutcome:
        try:
            await publisher.publish(
                EXPORT_PART_DONE_SUBJECT,
                done,
                msg_id_for_response(ids.part_id, ids.attempt, "done"),
            )
        except Exception as err:
            return retry(f"publish failed: {describe_unexpected(err)}")
        logger.info(
            "Export part already complete; answer replayed" if replayed else "Export part done",
            extra={
                **ids.log(),
                "files": len(done["files"]),
                "references": len(done["references"]),
                "replayed": replayed,
            },
        )
        return PartOutcome("done", message=done, replayed=replayed)

    marker_key = f"{prefix}{PART_DONE_MARKER}"
    try:
        # Idempotence. The same attempt delivered again (its ack was lost) replays the answer
        # it already gave: rewriting would change files the worker may be reading, and the new
        # answer would be dropped as a duplicate. Anything else starts from an empty prefix.
        previous = await _read_marker(store, marker_key, request)
        if previous is not None:
            return await publish_done(previous, True)
        await store.delete_prefix(prefix)
        ctx = PartContext(request, store, stop, clock)
        await handler(ctx)
        ctx.checkpoint()
        done = ctx.to_done()
        done_check = check_against("export-part-done", done)
        if not done_check.valid:
            raise ExportPartError(
                "internal",
                f"part.done does not match its schema: {'; '.join(done_check.errors)}",
            )
        await store.put(marker_key, _once(json.dumps(done).encode("utf-8")), "application/json")
        return await publish_done(done, False)
    except ExportAbortedError:
        return PartOutcome("aborted")
    except ExportPartError as err:
        await _cleanup(store, prefix, ids)
        return await fail(err.code, err.detail)
    except Exception as err:
        if stop.is_set():
            return PartOutcome("aborted")
        logger.error(
            "Export part handler error",
            extra={
                **ids.log(),
                "delivery": delivery_count,
                "error": describe_unexpected(err),
            },
            exc_info=err,
        )
        if delivery_count >= max_deliver:
            await _cleanup(store, prefix, ids)
            detail = f"{describe_unexpected(err)} on delivery {delivery_count}"
            return await fail("internal", detail)
        return retry(describe_unexpected(err))


async def _once(data: bytes) -> AsyncIterator[bytes]:
    yield data


async def _read_marker(store: PartStore, key: str, request: dict[str, Any]) -> PartDone | None:
    """The answer already given to this very attempt, if the part was completed before."""
    raw = await store.get(key)
    if raw is None:
        return None
    try:
        marker = json.loads(raw)
    except ValueError:
        return None
    if not check_against("export-part-done", marker).valid:
        return None
    if marker["partId"] != request["partId"] or marker["attempt"] != request["attempt"]:
        return None
    done: PartDone = marker
    return done


async def _cleanup(store: PartStore, prefix: str, ids: _Ids) -> None:
    """Best effort: a failed part leaves nothing behind (the worker also deletes the parts)."""
    try:
        await store.delete_prefix(prefix)
    except Exception as err:
        logger.warning(
            "Export part cleanup failed",
            extra={**ids.log(), "error": describe_unexpected(err)},
        )
