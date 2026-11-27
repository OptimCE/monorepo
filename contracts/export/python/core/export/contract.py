"""The export contract (contracts/export/README.md), as constants and helpers.

The JSON Schemas in ``schemas/`` are the source of truth for the wire format; ``validation``
checks every message against them at runtime.

This package is copied byte for byte into every Python annexe (``core/export/``) and compared
with the reference in the monorepo by ``scripts/check-export-parity.sh``: change it there.
"""

from __future__ import annotations

import re
from typing import Any, Literal

EXPORT_SCHEMA_VERSION = "1.0"
EXPORT_SCHEMA_MAJOR = 1

EXPORTS_STREAM = "EXPORTS"
EXPORT_PART_DONE_SUBJECT = "export.part.done"
EXPORT_PART_FAILED_SUBJECT = "export.part.failed"
DEFAULT_EXPORT_BUCKET = "exports"

# Redelivery policy of a part request (README §3, "Règles").
EXPORT_MAX_DELIVER = 5
EXPORT_ACK_WAIT_SECONDS = 60.0
# Delay before redelivery after the n-th failed delivery (index n - 1).
EXPORT_NAK_DELAYS_SECONDS: tuple[float, ...] = (10.0, 60.0, 300.0, 300.0)

# Written under the part's prefix once every file is complete, holding the export.part.done it
# answers. A redelivery of the same attempt replays it instead of rewriting files the worker may
# already be reading. Not an archive file: ``.export/`` is reserved and never listed in files.
PART_DONE_MARKER = ".export/done.json"
RESERVED_PART_DIR = ".export/"

ScopeType = Literal["user", "community"]
PartErrorCode = Literal[
    "scope_not_found", "forbidden", "corrupt_data", "unsupported_schema", "internal"
]
OmittedReason = Literal["below_threshold", "consent_missing"]

# The messages travel as plain dicts validated against the schemas; these aliases document them.
ExportRequest = dict[str, Any]
PartDone = dict[str, Any]
PartFailed = dict[str, Any]

_MAJOR = re.compile(r"^(\d+)\.\d+$")


def request_subject(service: str) -> str:
    return f"export.request.{service}"


def service_durable(service: str) -> str:
    return f"export-{service}"


def part_prefix(export_id: str, service: str) -> str:
    return f"parts/{export_id}/{service}/"


def msg_id_for_request(part_id: str, attempt: int) -> str:
    return f"{part_id}:{attempt}"


def msg_id_for_response(part_id: str, attempt: int, outcome: Literal["done", "failed"]) -> str:
    return f"{part_id}:{attempt}:{outcome}"


def schema_major(version: object) -> int | None:
    """``"1.3"`` → 1; anything unparsable → None."""
    if not isinstance(version, str):
        return None
    match = _MAJOR.match(version)
    return int(match.group(1)) if match else None
