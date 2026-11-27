"""handle_part and the contract check (copied with core/export)."""

from __future__ import annotations

import asyncio
import json
import uuid
from datetime import UTC, datetime
from typing import Any

import pytest

from core.export import (
    PART_DONE_MARKER,
    ExportPartError,
    MemoryPartStore,
    PartContext,
    check_against,
    empty_handler,
    handle_part,
    nak_delay,
    part_prefix,
    run_contract_check,
)

SERVICE = "billing"


def make_request(**overrides: Any) -> dict[str, Any]:
    export_id = str(uuid.uuid4())
    request = {
        "schemaVersion": "1.0",
        "exportId": export_id,
        "partId": str(uuid.uuid4()),
        "service": SERVICE,
        "attempt": 1,
        "scope": {"type": "user", "id": "auth0|member"},
        "requester": {"userId": "auth0|member"},
        "requestedAt": "2026-11-15T10:00:00Z",
        "storage": {"bucket": "exports", "prefix": part_prefix(export_id, SERVICE)},
    }
    request.update(overrides)
    return request


class RecordingPublisher:
    def __init__(self, failing: bool = False) -> None:
        self.sent: list[tuple[str, dict[str, Any], str]] = []
        self.failing = failing

    async def publish(self, subject: str, payload: dict[str, Any], msg_id: str) -> None:
        if self.failing:
            raise ConnectionError("broker down")
        self.sent.append((subject, payload, msg_id))


async def run(handler, request, *, delivery=1, store=None, publisher=None, stop=None, bucket=None):
    store = store if store is not None else MemoryPartStore()
    publisher = publisher if publisher is not None else RecordingPublisher()
    data = request if isinstance(request, str) else json.dumps(request)
    outcome = await handle_part(
        data,
        service=SERVICE,
        handler=handler,
        store=store,
        publisher=publisher,
        delivery_count=delivery,
        expected_bucket=bucket,
        stop=stop,
        now=lambda: datetime(2026, 11, 15, 10, 1, tzinfo=UTC),
    )
    return outcome, store, publisher


async def writes_invoices(ctx: PartContext) -> None:
    await ctx.write_json("invoices", [{"id": 1}])
    ctx.add_reference(
        bucket="optimce-documents",
        key="billing/invoices/2026/01/inv-1/inv-1.pdf",
        path="files/inv-1.pdf",
        content_type="application/pdf",
    )
    ctx.count("invoices", 1)


async def test_done_after_emptying_the_prefix_with_a_valid_answer_and_marker() -> None:
    request = make_request()
    store = MemoryPartStore()
    stale = f"{request['storage']['prefix']}stale.json"
    store.objects[stale] = (b"{}", "application/json")

    outcome, store, publisher = await run(writes_invoices, request, store=store)

    assert outcome.kind == "done"
    assert store.deleted == [stale]
    [(subject, payload, msg_id)] = publisher.sent
    assert subject == "export.part.done"
    assert msg_id == f"{request['partId']}:1:done"
    assert check_against("export-part-done", payload).valid
    assert payload["references"][0]["targetPath"] == "billing/files/inv-1.pdf"
    assert payload["summary"] == [{"labelKey": "export.billing.invoices", "count": 1}]
    marker = json.loads(store.text(f"{request['storage']['prefix']}{PART_DONE_MARKER}"))
    assert marker == payload
    assert [f["path"] for f in payload["files"]] == ["billing/invoices.json"]


async def test_a_completed_attempt_is_replayed_not_rewritten() -> None:
    request = make_request()
    store = MemoryPartStore()
    _, _, first = await run(writes_invoices, request, store=store)
    before = dict(store.objects)
    deleted = len(store.deleted)

    async def never_again(ctx: PartContext) -> None:
        raise AssertionError("the handler must not run twice for one attempt")

    outcome, _, second = await run(never_again, request, store=store, delivery=2)
    assert outcome.kind == "done"
    assert outcome.replayed
    assert second.sent == first.sent
    assert store.objects == before
    assert len(store.deleted) == deleted


async def test_a_newer_attempt_starts_again_from_an_empty_prefix() -> None:
    request = make_request()
    store = MemoryPartStore()

    async def old(ctx: PartContext) -> None:
        await ctx.write_json("old-only", [])

    await run(old, request, store=store)
    outcome, _, _ = await run(writes_invoices, {**request, "attempt": 2}, store=store)
    assert outcome.kind == "done"
    assert outcome.message["attempt"] == 2
    assert f"{request['storage']['prefix']}old-only.json" not in store.objects


async def test_an_unreadable_marker_is_ignored() -> None:
    request = make_request()
    store = MemoryPartStore()
    store.objects[f"{request['storage']['prefix']}{PART_DONE_MARKER}"] = (b"{no", "x/y")
    outcome, _, _ = await run(writes_invoices, request, store=store)
    assert outcome.kind == "done"
    assert not outcome.replayed


async def test_an_empty_service_answers_an_empty_part() -> None:
    outcome, _, _ = await run(empty_handler, make_request())
    assert outcome.kind == "done"
    assert outcome.message["files"] == []
    assert outcome.message["references"] == []


async def test_export_part_error_answers_failed_and_leaves_nothing() -> None:
    request = make_request()

    async def forbidden(ctx: PartContext) -> None:
        await ctx.write_json("invoices", [{"id": 1}])
        raise ExportPartError("forbidden", "requester is not ADMIN of the community")

    outcome, store, publisher = await run(forbidden, request)
    assert outcome.kind == "failed"
    assert not [k for k in store.objects if k.startswith(request["storage"]["prefix"])]
    [(subject, payload, msg_id)] = publisher.sent
    assert subject == "export.part.failed"
    assert msg_id == f"{request['partId']}:1:failed"
    assert payload["errorCode"] == "forbidden"
    assert check_against("export-part-failed", payload).valid


async def test_an_unexpected_error_is_retried_with_the_contract_delays() -> None:
    async def boom(ctx: PartContext) -> None:
        raise ConnectionResetError("connection reset")

    outcome, _, publisher = await run(boom, make_request(), delivery=1)
    assert (outcome.kind, outcome.delay) == ("retry", 10.0)
    assert publisher.sent == []
    outcome, _, _ = await run(boom, make_request(), delivery=3)
    assert (outcome.kind, outcome.delay) == ("retry", 300.0)


async def test_the_last_delivery_fails_naming_the_error_class_not_its_message() -> None:
    class UniqueViolationError(Exception):
        sqlstate = "23505"

    async def leaky(ctx: PartContext) -> None:
        raise UniqueViolationError("duplicate key (email)=(alice@example.com)")

    outcome, _, publisher = await run(leaky, make_request(), delivery=5)
    assert outcome.kind == "failed"
    detail = publisher.sent[0][1]["errorDetail"]
    assert detail == "UniqueViolationError (23505) on delivery 5"
    assert "alice" not in detail


@pytest.mark.parametrize("data", ["not json", json.dumps({"exportId": "x"})])
async def test_unanswerable_messages_are_invalid(data: str) -> None:
    outcome, _, _ = await run(empty_handler, data)
    assert outcome.kind == "invalid"


async def test_another_major_version_is_unsupported() -> None:
    outcome, _, _ = await run(empty_handler, make_request(schemaVersion="2.0"))
    assert (outcome.kind, outcome.message["errorCode"]) == (
        "failed",
        "unsupported_schema",
    )


def _other_export(r: dict[str, Any]) -> dict[str, Any]:
    return {
        **r,
        "storage": {**r["storage"], "prefix": part_prefix(str(uuid.uuid4()), SERVICE)},
    }


@pytest.mark.parametrize(
    "mutate",
    [
        lambda r: {**r, "email": "alice@example.com"},
        lambda r: {
            **r,
            "service": "crm",
            "storage": {**r["storage"], "prefix": part_prefix(r["exportId"], "crm")},
        },
        _other_export,
    ],
    ids=["unknown-field", "other-service", "other-export-prefix"],
)
async def test_inconsistent_requests_are_refused(mutate) -> None:
    outcome, _, publisher = await run(empty_handler, mutate(make_request()))
    assert (outcome.kind, outcome.message["errorCode"]) == ("failed", "internal")
    assert "alice" not in json.dumps(publisher.sent)


async def test_a_request_for_another_bucket_is_refused_when_bound() -> None:
    request = make_request()
    request["storage"] = {**request["storage"], "bucket": "crm-files"}
    outcome, _, _ = await run(empty_handler, request, bucket="exports")
    assert (outcome.kind, outcome.message["errorCode"]) == ("failed", "internal")


async def test_a_shutdown_is_aborted_for_an_immediate_nak() -> None:
    stop = asyncio.Event()

    async def handler(ctx: PartContext) -> None:
        stop.set()
        ctx.checkpoint()

    outcome, _, _ = await run(handler, make_request(), stop=stop)
    assert outcome.kind == "aborted"


async def test_an_unpublishable_answer_is_retried() -> None:
    outcome, _, _ = await run(empty_handler, make_request(), publisher=RecordingPublisher(True))
    assert outcome.kind == "retry"


def test_nak_delay_follows_the_ladder_then_stays_at_the_last_step() -> None:
    ladder = (10.0, 60.0, 300.0, 300.0)
    assert [nak_delay(ladder, n) for n in (1, 2, 3, 4, 5, 9)] == [
        10,
        60,
        300,
        300,
        300,
        300,
    ]


async def test_the_contract_check_passes_an_empty_handler() -> None:
    result = await run_contract_check(
        empty_handler,
        service="news-board",
        scope={"type": "community", "id": "2"},
        requester_id="auth0|admin",
    )
    assert result.outcome == "done"


async def test_the_contract_check_fails_a_handler_that_never_answers() -> None:
    async def stuck(ctx: PartContext) -> None:
        await asyncio.Event().wait()

    with pytest.raises(AssertionError, match="no answer within 0.05 s"):
        await run_contract_check(
            stuck,
            service="crm",
            scope={"type": "user", "id": "u"},
            requester_id="u",
            limit_seconds=0.05,
        )
