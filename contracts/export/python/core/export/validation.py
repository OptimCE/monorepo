"""Runtime validation against the vendored contract schemas (``core/export/schemas``)."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path
from typing import Any, Literal

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

SchemaName = Literal[
    "export-job-requested",
    "export-request",
    "export-part-done",
    "export-part-failed",
    "manifest",
    "data-file",
]

_SCHEMA_DIR = Path(__file__).resolve().parent / "schemas"
_BASE = "https://optimce.be/contracts/export/"


@dataclass(frozen=True)
class SchemaCheck:
    valid: bool
    # Short, content-free description: JSON pointers and keywords only, never the values.
    errors: list[str] = field(default_factory=list)


@cache
def _validators() -> dict[str, Draft202012Validator]:
    schemas: dict[str, dict[str, Any]] = {}
    for path in sorted(_SCHEMA_DIR.glob("*.schema.json")):
        schema = json.loads(path.read_text(encoding="utf-8"))
        schemas[schema["$id"]] = schema
    registry: Registry = Registry().with_resources(
        (uri, Resource.from_contents(schema)) for uri, schema in schemas.items()
    )
    return {
        uri: Draft202012Validator(schema, registry=registry, format_checker=FormatChecker())
        for uri, schema in schemas.items()
    }


def check_against(name: SchemaName, value: object) -> SchemaCheck:
    validator = _validators().get(f"{_BASE}{name}.schema.json")
    if validator is None:
        raise RuntimeError(f"export schema {name} is not loaded from {_SCHEMA_DIR}")
    errors = sorted(validator.iter_errors(value), key=lambda e: list(e.absolute_path))
    described = [
        f"/{'/'.join(str(p) for p in error.absolute_path)} {error.validator}" for error in errors
    ]
    return SchemaCheck(valid=not errors, errors=described[:10])
