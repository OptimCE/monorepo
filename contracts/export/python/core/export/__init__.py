"""export-handler-kit, Python side (contracts/export/README.md).

A service handler only selects its data and writes it through PartContext; the kit does the
subscription, the MinIO writes, the checksums, the done/failed answer and the idempotence.

This package is a byte copy of contracts/export/python/core/export in the monorepo, checked by
scripts/check-export-parity.sh. Change the reference, then copy it.
"""

from .context import PartContext, csv_field, iso_utc, safe_file_name
from .contract import (
    DEFAULT_EXPORT_BUCKET,
    EXPORT_SCHEMA_VERSION,
    EXPORTS_STREAM,
    PART_DONE_MARKER,
    part_prefix,
    request_subject,
    service_durable,
)
from .contract_check import ContractCheckResult, run_contract_check
from .errors import ExportAbortedError, ExportPartError, describe_unexpected
from .requester import CrmLookup, Requester, SqlCrmLookup, resolve_requester
from .runner import (
    ExportHandler,
    PartOutcome,
    PartPublisher,
    empty_handler,
    handle_part,
    nak_delay,
)
from .store import ExportStorageSettings, MemoryPartStore, PartStore, S3PartStore
from .validation import SchemaCheck, check_against

__all__ = [
    "DEFAULT_EXPORT_BUCKET",
    "EXPORTS_STREAM",
    "EXPORT_SCHEMA_VERSION",
    "PART_DONE_MARKER",
    "ContractCheckResult",
    "CrmLookup",
    "ExportAbortedError",
    "ExportHandler",
    "ExportPartError",
    "ExportStorageSettings",
    "MemoryPartStore",
    "PartContext",
    "PartOutcome",
    "PartPublisher",
    "PartStore",
    "Requester",
    "S3PartStore",
    "SchemaCheck",
    "SqlCrmLookup",
    "check_against",
    "csv_field",
    "describe_unexpected",
    "empty_handler",
    "handle_part",
    "iso_utc",
    "nak_delay",
    "part_prefix",
    "request_subject",
    "resolve_requester",
    "run_contract_check",
    "safe_file_name",
    "service_durable",
]
