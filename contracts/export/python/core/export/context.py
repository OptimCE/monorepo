"""PartContext: what a handler writes its part through."""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import re
from collections.abc import (
    AsyncGenerator,
    AsyncIterable,
    AsyncIterator,
    Callable,
    Iterable,
    Sequence,
)
from dataclasses import dataclass
from datetime import UTC, date, datetime
from decimal import Decimal
from typing import Any

from .contract import (
    EXPORT_SCHEMA_VERSION,
    RESERVED_PART_DIR,
    ExportRequest,
    OmittedReason,
    PartDone,
)
from .errors import ExportAbortedError
from .store import PartStore

# Same rule as `archivePath` in common.schema.json.
_RELATIVE_PATH = re.compile(r"^(?!/)(?!.*(?:^|/)\.{1,2}(?:/|$))[^\\\x00-\x1f]+$")
_ENTITY = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
_NAME = re.compile(r"^[a-z0-9_.-]+$")
_UNSAFE = re.compile(r"[\\/\x00-\x1f\x7f]+")
_MAX_PATH = 512
_FLUSH_CHARS = 64 * 1024

CsvValue = str | int | float | bool | Decimal | date | datetime | None


def iso_utc(value: datetime) -> str:
    """ISO 8601 in UTC with a Z, as the contract writes every date."""
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _json_default(value: object) -> object:
    if isinstance(value, datetime):
        return iso_utc(value)
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    raise TypeError(f"{type(value).__name__} is not JSON serialisable in an export")


@dataclass(frozen=True)
class _Written:
    path: str
    key: str
    size: int
    sha256: str
    content_type: str


class PartContext:
    """Every path is relative to the service's own folder of the archive (``<service>/…``).

    The context adds the folder, refuses a path outside it or written twice, and computes each
    file's size and sha256 while streaming it to the store.
    """

    def __init__(
        self,
        request: ExportRequest,
        store: PartStore,
        stop: asyncio.Event | None = None,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.request = request
        self._store = store
        self._stop = stop or asyncio.Event()
        self._now = now or (lambda: datetime.now(UTC))
        self._files: list[_Written] = []
        self._references: list[dict[str, Any]] = []
        self._counters: dict[str, int] = {}
        self._omissions: list[dict[str, str]] = []
        self._claimed: set[str] = set()

    @property
    def service(self) -> str:
        return str(self.request["service"])

    @property
    def scope_type(self) -> str:
        return str(self.request["scope"]["type"])

    @property
    def scope_id(self) -> str:
        return str(self.request["scope"]["id"])

    @property
    def requester_id(self) -> str:
        return str(self.request["requester"]["userId"])

    def checkpoint(self) -> None:
        """Raises ExportAbortedError once the consumer is shutting down. Call it in long loops."""
        if self._stop.is_set():
            raise ExportAbortedError("export part aborted by shutdown")

    async def write_json(
        self,
        entity: str,
        items: Iterable[Any] | AsyncIterable[Any],
        *,
        path: str | None = None,
    ) -> int:
        """Streams one entity type as ``<service>/<entity>.json`` in the data-file envelope.

        ``items`` may be an async iterable, so a cursor never has to be materialised. Returns
        the number of items written.
        """
        if not _ENTITY.match(entity):
            raise ValueError(f"invalid entity name {entity!r}")
        header = json.dumps(
            {
                "schemaVersion": EXPORT_SCHEMA_VERSION,
                "service": self.service,
                "entity": entity,
                "scope": self.scope_type,
                "generatedAt": iso_utc(self._now()),
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        count = 0

        async def produce() -> AsyncGenerator[str, None]:
            nonlocal count
            yield f'{header[:-1]},"items":['
            async with contextlib.aclosing(_aiter(items)) as source:
                async for item in source:
                    text = json.dumps(
                        item,
                        ensure_ascii=False,
                        separators=(",", ":"),
                        default=_json_default,
                    )
                    yield ("\n" if count == 0 else ",\n") + text
                    count += 1
            yield "]}\n" if count == 0 else "\n]}\n"

        await self._write_object(path or f"{entity}.json", "application/json", produce)
        return count

    async def write_csv(
        self,
        path: str,
        header: Sequence[str],
        rows: Iterable[Sequence[CsvValue]] | AsyncIterable[Sequence[CsvValue]],
    ) -> int:
        """Streams a CSV file (UTF-8, comma, header line). Returns the number of data rows."""
        count = 0

        async def produce() -> AsyncGenerator[str, None]:
            nonlocal count
            yield ",".join(csv_field(h) for h in header) + "\r\n"
            async with contextlib.aclosing(_aiter(rows)) as source:
                async for row in source:
                    if len(row) != len(header):
                        raise ValueError(
                            f"CSV row {count + 1} of {path} has {len(row)} fields, "
                            f"header has {len(header)}"
                        )
                    yield ",".join(csv_field(v) for v in row) + "\r\n"
                    count += 1

        await self._write_object(path, "text/csv; charset=utf-8", produce)
        return count

    def add_reference(
        self,
        *,
        bucket: str,
        key: str,
        path: str,
        size: int | None = None,
        sha256: str | None = None,
        content_type: str | None = None,
    ) -> None:
        """Lists an object already in MinIO; the worker copies it to ``<service>/<path>``."""
        reference: dict[str, Any] = {
            "bucket": bucket,
            "key": key,
            "targetPath": self._claim(path),
        }
        if size is not None:
            reference["size"] = size
        if sha256 is not None:
            reference["sha256"] = sha256
        if content_type is not None:
            reference["contentType"] = content_type
        self._references.append(reference)

    def count(self, name: str, n: int) -> None:
        """Adds to the counter shown in index.html as ``export.<service>.<name>``."""
        if not _NAME.match(name):
            raise ValueError(f"invalid counter name {name!r}")
        if isinstance(n, bool) or not isinstance(n, int) or n < 0:
            raise ValueError(f"invalid count {n!r} for {name}")
        label = f"export.{self.service}.{name}"
        self._counters[label] = self._counters.get(label, 0) + n

    def omit(self, what: str, reason: OmittedReason) -> None:
        """Records something deliberately left out (``<service>.<what>``)."""
        if not _NAME.match(what):
            raise ValueError(f"invalid omission name {what!r}")
        self._omissions.append({"what": f"{self.service}.{what}", "reason": reason})

    def to_done(self) -> PartDone:
        return {
            "schemaVersion": EXPORT_SCHEMA_VERSION,
            "exportId": self.request["exportId"],
            "partId": self.request["partId"],
            "service": self.service,
            "attempt": self.request["attempt"],
            "files": [
                {
                    "path": f.path,
                    "key": f.key,
                    "size": f.size,
                    "sha256": f.sha256,
                    "contentType": f.content_type,
                }
                for f in self._files
            ],
            "references": list(self._references),
            "summary": [{"labelKey": k, "count": v} for k, v in self._counters.items()],
            "omitted": list(self._omissions),
            "producedAt": iso_utc(self._now()),
        }

    def _claim(self, relative: str) -> str:
        """Validates a service-relative path, reserves it, and returns its archive path."""
        if not _RELATIVE_PATH.match(relative):
            raise ValueError(f"invalid archive path {relative!r}")
        if relative.startswith(RESERVED_PART_DIR):
            raise ValueError(f"{RESERVED_PART_DIR} is reserved for the kit")
        path = f"{self.service}/{relative}"
        if len(path) > _MAX_PATH:
            raise ValueError(f"archive path longer than {_MAX_PATH} characters")
        if path in self._claimed:
            raise ValueError(f"archive path written twice: {path}")
        self._claimed.add(path)
        return path

    async def _write_object(
        self,
        relative: str,
        content_type: str,
        produce: Callable[[], AsyncGenerator[str, None]],
    ) -> None:
        self.checkpoint()
        path = self._claim(relative)
        key = f"{self.request['storage']['prefix']}{relative}"
        digest = hashlib.sha256()
        size = 0

        async def chunks() -> AsyncIterator[bytes]:
            nonlocal size
            pending: list[str] = []
            pending_chars = 0
            # Closed on any exit: a failure (or a shutdown) mid-file must not leave the
            # handler's own generator, and the reads it holds open, suspended until the GC.
            async with contextlib.aclosing(produce()) as texts:
                async for text in texts:
                    self.checkpoint()
                    pending.append(text)
                    pending_chars += len(text)
                    if pending_chars >= _FLUSH_CHARS:
                        data = "".join(pending).encode("utf-8")
                        pending, pending_chars = [], 0
                        digest.update(data)
                        size += len(data)
                        yield data
            if pending:
                data = "".join(pending).encode("utf-8")
                digest.update(data)
                size += len(data)
                yield data

        await self._store.put(key, chunks(), content_type)
        self._files.append(_Written(path, key, size, digest.hexdigest(), content_type))


async def _aiter(items: Iterable[Any] | AsyncIterable[Any]) -> AsyncGenerator[Any, None]:
    """Any iterable as an async iterator; closing it closes the handler's generator too."""
    if isinstance(items, AsyncIterable):
        iterator = aiter(items)
        try:
            async for item in iterator:
                yield item
        finally:
            close = getattr(iterator, "aclose", None)
            if close is not None:
                await close()
    else:
        for item in items:
            yield item


def csv_field(value: CsvValue) -> str:
    """RFC 4180 field. Values are written as stored: the archive is data, not a report."""
    if value is None:
        return ""
    if isinstance(value, datetime):
        text = iso_utc(value)
    elif isinstance(value, date):
        text = value.isoformat()
    elif isinstance(value, bool):
        text = "true" if value else "false"
    else:
        text = str(value)
    if any(c in text for c in ',"\r\n') or text != text.strip():
        return '"' + text.replace('"', '""') + '"'
    return text


def safe_file_name(name: str, max_length: int = 120) -> str:
    """Turns a stored file name into a safe path segment.

    No separator, no control character, at most ``max_length`` characters with the extension
    kept. Accents and spaces are kept (the schema allows them).
    """
    cleaned = _UNSAFE.sub("_", name).strip().lstrip(".").rstrip(". ")
    if not cleaned:
        cleaned = "file"
    if len(cleaned) <= max_length:
        return cleaned
    dot = cleaned.rfind(".")
    extension = cleaned[dot:] if dot > 0 and len(cleaned) - dot <= 10 else ""
    return cleaned[: max_length - len(extension)] + extension
