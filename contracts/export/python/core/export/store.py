"""Where a service writes its part: the ``exports`` bucket, under ``parts/<exportId>/<service>/``.

Narrow on purpose: a service only creates, reads and deletes objects under its own prefix (its
``export-<service>`` MinIO account allows nothing else). Size and sha256 are computed while
writing; the only object read back is the small done marker.
"""

from __future__ import annotations

import contextlib
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any, Protocol

_PART_SIZE = 5 * 1024 * 1024


class PartStore(Protocol):
    async def put(self, key: str, chunks: AsyncIterator[bytes], content_type: str) -> None:
        """Streams ``chunks`` to ``key``. Returns once the object is complete in the bucket."""

    async def get(self, key: str) -> bytes | None:
        """The object's bytes, or None when there is none. For small objects only."""

    async def delete_prefix(self, prefix: str) -> int:
        """Deletes every object under ``prefix``; returns how many there were."""


class MemoryPartStore:
    """In-memory store for tests and the contract check."""

    def __init__(self) -> None:
        self.objects: dict[str, tuple[bytes, str]] = {}
        # Every key ever deleted, in order: lets a test prove a prefix was emptied first.
        self.deleted: list[str] = []

    async def put(self, key: str, chunks: AsyncIterator[bytes], content_type: str) -> None:
        parts = [chunk async for chunk in chunks]
        self.objects[key] = (b"".join(parts), content_type)

    async def get(self, key: str) -> bytes | None:
        item = self.objects.get(key)
        return item[0] if item else None

    async def delete_prefix(self, prefix: str) -> int:
        keys = [k for k in self.objects if k.startswith(prefix)]
        for key in keys:
            del self.objects[key]
            self.deleted.append(key)
        return len(keys)

    def text(self, key: str) -> str:
        return self.objects[key][0].decode("utf-8")


@dataclass(frozen=True)
class ExportStorageSettings:
    """The export credentials of one service, NOT its usual storage account."""

    endpoint: str
    access_key: str
    secret_key: str
    region: str = "us-east-1"
    bucket: str = "exports"

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> ExportStorageSettings:
        values = os.environ if env is None else env
        endpoint = values.get("EXPORT_STORAGE_ENDPOINT") or values.get("STORAGE_ENDPOINT") or ""
        access_key = values.get("EXPORT_STORAGE_ACCESS_KEY", "")
        secret_key = values.get("EXPORT_STORAGE_SECRET_KEY", "")
        missing = [
            name
            for name, value in (
                ("EXPORT_STORAGE_ENDPOINT", endpoint),
                ("EXPORT_STORAGE_ACCESS_KEY", access_key),
                ("EXPORT_STORAGE_SECRET_KEY", secret_key),
            )
            if not value
        ]
        if missing:
            raise RuntimeError(f"export storage is not configured: {', '.join(missing)} missing")
        return cls(
            endpoint=endpoint,
            access_key=access_key,
            secret_key=secret_key,
            region=values.get("EXPORT_STORAGE_REGION")
            or values.get("STORAGE_REGION")
            or "us-east-1",
            bucket=values.get("EXPORT_BUCKET", "exports"),
        )


class S3PartStore:
    """aiobotocore implementation.

    ``put`` uploads 5 MiB parts one at a time as the chunks arrive, so memory stays at about one
    part whatever the size of the file. A file smaller than one part is a single PutObject.
    """

    def __init__(self, settings: ExportStorageSettings) -> None:
        self._settings = settings

    @asynccontextmanager
    async def _client(self) -> AsyncIterator[Any]:
        from aiobotocore.session import get_session

        session = get_session()
        async with session.create_client(
            "s3",
            endpoint_url=self._settings.endpoint,
            region_name=self._settings.region,
            aws_access_key_id=self._settings.access_key,
            aws_secret_access_key=self._settings.secret_key,
        ) as client:
            yield client

    async def put(self, key: str, chunks: AsyncIterator[bytes], content_type: str) -> None:
        bucket = self._settings.bucket
        async with self._client() as client:
            buffer = bytearray()
            upload_id: str | None = None
            parts: list[dict[str, Any]] = []
            try:
                async for chunk in chunks:
                    buffer.extend(chunk)
                    while len(buffer) >= _PART_SIZE:
                        if upload_id is None:
                            created = await client.create_multipart_upload(
                                Bucket=bucket, Key=key, ContentType=content_type
                            )
                            upload_id = str(created["UploadId"])
                        body = bytes(buffer[:_PART_SIZE])
                        del buffer[:_PART_SIZE]
                        number = len(parts) + 1
                        sent = await client.upload_part(
                            Bucket=bucket,
                            Key=key,
                            UploadId=upload_id,
                            PartNumber=number,
                            Body=body,
                        )
                        parts.append({"ETag": sent["ETag"], "PartNumber": number})
                if upload_id is None:
                    await client.put_object(
                        Bucket=bucket,
                        Key=key,
                        Body=bytes(buffer),
                        ContentType=content_type,
                    )
                    return
                if buffer:
                    number = len(parts) + 1
                    sent = await client.upload_part(
                        Bucket=bucket,
                        Key=key,
                        UploadId=upload_id,
                        PartNumber=number,
                        Body=bytes(buffer),
                    )
                    parts.append({"ETag": sent["ETag"], "PartNumber": number})
                await client.complete_multipart_upload(
                    Bucket=bucket,
                    Key=key,
                    UploadId=upload_id,
                    MultipartUpload={"Parts": parts},
                )
            except BaseException:
                if upload_id is not None:
                    await _abort_quietly(client, bucket, key, upload_id)
                raise

    async def get(self, key: str) -> bytes | None:
        from botocore.exceptions import ClientError

        async with self._client() as client:
            try:
                response = await client.get_object(Bucket=self._settings.bucket, Key=key)
            except ClientError as err:
                if err.response.get("Error", {}).get("Code") in {"NoSuchKey", "404"}:
                    return None
                raise
            async with response["Body"] as stream:
                data: bytes = await stream.read()
                return data

    async def delete_prefix(self, prefix: str) -> int:
        bucket = self._settings.bucket
        deleted = 0
        async with self._client() as client:
            paginator = client.get_paginator("list_objects_v2")
            async for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
                keys = [{"Key": item["Key"]} for item in page.get("Contents", [])]
                if not keys:
                    continue
                result = await client.delete_objects(
                    Bucket=bucket, Delete={"Objects": keys, "Quiet": True}
                )
                errors = result.get("Errors") or []
                if errors:
                    code = errors[0].get("Code", "unknown")
                    raise RuntimeError(
                        f"delete of {len(errors)} object(s) under {prefix} failed: {code}"
                    )
                deleted += len(keys)
        return deleted


async def _abort_quietly(client: Any, bucket: str, key: str, upload_id: str) -> None:
    # Best effort: the ILM rule and MinIO's stale-upload sweep clean up what this misses.
    with contextlib.suppress(Exception):
        await client.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)
