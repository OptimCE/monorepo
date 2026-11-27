"""PartContext and its helpers (copied with core/export; see scripts/check-export-parity.sh)."""

from __future__ import annotations

import asyncio
import hashlib
import json
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import pytest

from core.export import (
    ExportAbortedError,
    MemoryPartStore,
    PartContext,
    check_against,
    csv_field,
    part_prefix,
    safe_file_name,
)
from core.export.context import CsvValue

NOW = datetime(2026, 11, 15, 10, 1, tzinfo=UTC)


def make_request(service: str = "billing", scope_type: str = "user") -> dict:
    export_id = str(uuid.uuid4())
    return {
        "schemaVersion": "1.0",
        "exportId": export_id,
        "partId": str(uuid.uuid4()),
        "service": service,
        "attempt": 1,
        "scope": {"type": scope_type, "id": "auth0|member"},
        "requester": {"userId": "auth0|member"},
        "requestedAt": "2026-11-15T10:00:00Z",
        "storage": {"bucket": "exports", "prefix": part_prefix(export_id, service)},
    }


def make_ctx(store: MemoryPartStore | None = None, **kwargs) -> PartContext:
    return PartContext(make_request(**kwargs), store or MemoryPartStore(), now=lambda: NOW)


async def test_write_json_streams_the_envelope_with_size_and_sha256() -> None:
    store = MemoryPartStore()
    ctx = make_ctx(store)

    async def invoices():
        yield {"id": 1, "label": 'Élise, "la" première', "amount": Decimal("12.50")}
        yield {"id": 2, "issued_at": datetime(2026, 1, 1, 12, tzinfo=UTC)}

    assert await ctx.write_json("invoices", invoices()) == 2
    file = ctx.to_done()["files"][0]
    assert file["path"] == "billing/invoices.json"
    assert file["key"] == f"{ctx.request['storage']['prefix']}invoices.json"
    stored = store.objects[file["key"]][0]
    assert file["size"] == len(stored)
    assert file["sha256"] == hashlib.sha256(stored).hexdigest()
    parsed = json.loads(stored)
    assert check_against("data-file", parsed).valid
    assert parsed["generatedAt"] == "2026-11-15T10:01:00Z"
    assert parsed["items"] == [
        {"id": 1, "label": 'Élise, "la" première', "amount": "12.50"},
        {"id": 2, "issued_at": "2026-01-01T12:00:00Z"},
    ]


async def test_an_empty_entity_is_an_empty_items_array() -> None:
    store = MemoryPartStore()
    ctx = make_ctx(store)
    assert await ctx.write_json("payments", []) == 0
    assert json.loads(store.text(ctx.to_done()["files"][0]["key"]))["items"] == []


async def test_a_large_stream_stays_intact_across_flushes() -> None:
    store = MemoryPartStore()
    ctx = make_ctx(store)
    count = await ctx.write_json("big", ({"i": i, "t": "x" * 20} for i in range(20_000)))
    assert count == 20_000
    file = ctx.to_done()["files"][0]
    assert json.loads(store.text(file["key"]))["items"][-1] == {
        "i": 19_999,
        "t": "x" * 20,
    }
    assert file["size"] == len(store.objects[file["key"]][0])


async def test_write_csv_is_rfc_4180_and_refuses_a_row_of_the_wrong_width() -> None:
    store = MemoryPartStore()
    ctx = make_ctx(store)
    rows: list[tuple[CsvValue, ...]] = [
        (datetime(2026, 1, 1, 0, 15, tzinfo=UTC), 0.25, 'a "quoted", value'),
        ("2026-01-01T00:30:00Z", None, " padded"),
    ]
    await ctx.write_csv("curves/2026.csv", ["timestamp_utc", "offtake_kwh", "note"], rows)
    file = ctx.to_done()["files"][0]
    assert file["contentType"] == "text/csv; charset=utf-8"
    assert store.text(file["key"]) == (
        "timestamp_utc,offtake_kwh,note\r\n"
        '2026-01-01T00:15:00Z,0.25,"a ""quoted"", value"\r\n'
        '2026-01-01T00:30:00Z,," padded"\r\n'
    )
    with pytest.raises(ValueError, match="2"):
        await ctx.write_csv("bad.csv", ["a", "b"], [["only one"]])


@pytest.mark.parametrize(
    "path",
    [
        "../crm/x.json",
        "/etc/passwd",
        "a\\b.json",
        "a/./b.json",
        "a/../b.json",
        "a\nb",
        "",
    ],
)
async def test_unsafe_paths_are_refused(path: str) -> None:
    with pytest.raises(ValueError, match="invalid archive path"):
        await make_ctx().write_csv(path, ["a"], [])


async def test_dot_export_is_reserved_for_the_kit() -> None:
    with pytest.raises(ValueError, match="reserved"):
        await make_ctx().write_json("x", [], path=".export/done.json")


async def test_a_path_is_written_once_references_included() -> None:
    ctx = make_ctx()
    await ctx.write_json("invoices", [])
    with pytest.raises(ValueError, match="twice"):
        await ctx.write_json("invoices", [])
    ctx.add_reference(bucket="optimce-documents", key="billing/a.pdf", path="files/1-a.pdf")
    with pytest.raises(ValueError, match="twice"):
        ctx.add_reference(bucket="optimce-documents", key="billing/b.pdf", path="files/1-a.pdf")


def test_counters_and_omissions_are_namespaced_by_service() -> None:
    ctx = make_ctx()
    ctx.count("invoices", 2)
    ctx.count("invoices", 3)
    ctx.omit("aggregate", "below_threshold")
    done = ctx.to_done()
    assert done["summary"] == [{"labelKey": "export.billing.invoices", "count": 5}]
    assert done["omitted"] == [{"what": "billing.aggregate", "reason": "below_threshold"}]
    with pytest.raises(ValueError, match="invalid counter name"):
        ctx.count("Invoices", 1)
    with pytest.raises(ValueError, match="invalid count"):
        ctx.count("invoices", -1)


async def test_writing_stops_once_the_consumer_shuts_down() -> None:
    stop = asyncio.Event()
    ctx = PartContext(make_request(), MemoryPartStore(), stop, now=lambda: NOW)

    def rows():
        yield {"i": 0}
        stop.set()
        yield {"i": 1}

    with pytest.raises(ExportAbortedError):
        await ctx.write_json("x", rows())


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("statuts.pdf", "statuts.pdf"),
        ("../../etc/passwd", "_.._etc_passwd"),
        ("a\\b/c", "a_b_c"),
        ("tab\there", "tab_here"),
        ("   ", "file"),
        (".hidden", "hidden"),
        (
            "Convention de partage, Liège été.pdf",
            "Convention de partage, Liège été.pdf",
        ),
    ],
)
async def test_safe_file_name_gives_one_accepted_segment(raw: str, expected: str) -> None:
    name = safe_file_name(raw)
    assert name == expected
    assert await make_ctx().write_csv(f"files/{name}", ["a"], []) == 0


def test_safe_file_name_keeps_the_extension_when_it_shortens() -> None:
    name = safe_file_name("a" * 300 + ".pdf", 50)
    assert len(name) == 50
    assert name.endswith(".pdf")


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (None, ""),
        (12.5, "12.5"),
        ("plain", "plain"),
        ("a,b", '"a,b"'),
        ('say "hi"', '"say ""hi"""'),
        ("line\nbreak", '"line\nbreak"'),
        (True, "true"),
    ],
)
def test_csv_field_quotes_only_what_rfc_4180_needs(value: object, expected: str) -> None:
    assert csv_field(value) == expected  # type: ignore[arg-type]
