"""The contract test every service runs in its own CI (README §10).

One request on a fixture scope must be answered with a schema-valid done or failed within
``limit_seconds`` (60 by default). Raises AssertionError with an explicit reason otherwise.
"""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from .context import iso_utc
from .contract import EXPORT_SCHEMA_VERSION, part_prefix
from .runner import ExportHandler, handle_part
from .store import MemoryPartStore
from .validation import SchemaName, check_against


@dataclass(frozen=True)
class ContractCheckResult:
    outcome: str
    message: dict[str, Any]
    store: MemoryPartStore
    elapsed: float


class _RecordingPublisher:
    def __init__(self) -> None:
        self.sent: list[tuple[str, dict[str, Any]]] = []

    async def publish(self, subject: str, payload: dict[str, Any], msg_id: str) -> None:
        self.sent.append((subject, payload))


async def run_contract_check(
    handler: ExportHandler,
    *,
    service: str,
    scope: dict[str, str],
    requester_id: str,
    limit_seconds: float = 60.0,
) -> ContractCheckResult:
    export_id = str(uuid.uuid4())
    request = {
        "schemaVersion": EXPORT_SCHEMA_VERSION,
        "exportId": export_id,
        "partId": str(uuid.uuid4()),
        "service": service,
        "attempt": 1,
        "scope": scope,
        "requester": {"userId": requester_id},
        "requestedAt": iso_utc(datetime.now(UTC)),
        "storage": {"bucket": "exports", "prefix": part_prefix(export_id, service)},
    }
    store = MemoryPartStore()
    publisher = _RecordingPublisher()
    started = time.monotonic()
    try:
        async with asyncio.timeout(limit_seconds):
            outcome = await handle_part(
                json.dumps(request).encode("utf-8"),
                service=service,
                handler=handler,
                store=store,
                publisher=publisher,
                delivery_count=1,
            )
    except TimeoutError as err:
        raise AssertionError(f"contract check: no answer within {limit_seconds} s") from err

    if outcome.kind not in ("done", "failed"):
        raise AssertionError(
            f"contract check: handler did not answer ({outcome.kind}: {outcome.reason})"
        )
    if len(publisher.sent) != 1:
        raise AssertionError(f"contract check: expected one answer, got {len(publisher.sent)}")
    schema: SchemaName = "export-part-done" if outcome.kind == "done" else "export-part-failed"
    check = check_against(schema, publisher.sent[0][1])
    if not check.valid:
        raise AssertionError(f"contract check: answer does not match {schema}: {check.errors}")
    for file in outcome.message.get("files", []) if outcome.kind == "done" else []:
        if not file["path"].startswith(f"{service}/"):
            raise AssertionError(f"contract check: {file['path']} is outside {service}/")
        if file["key"] not in store.objects:
            raise AssertionError(f"contract check: {file['key']} listed but not written")
    return ContractCheckResult(outcome.kind, outcome.message, store, time.monotonic() - started)
