"""Errors a handler raises to steer the answer to its part request."""

from __future__ import annotations

from .contract import PartErrorCode


class ExportPartError(Exception):
    """A non-recoverable failure of a part: the kit answers export.part.failed and acks.

    Raise it from a handler for a definitive outcome (unknown scope, requester no longer
    allowed, inconsistent data). ``detail`` goes to the worker and the logs: identifiers only,
    never exported content or personal data. Any other exception is treated as transient and
    redelivered.
    """

    def __init__(self, code: PartErrorCode, detail: str) -> None:
        super().__init__(f"{code}: {detail}")
        self.code: PartErrorCode = code
        self.detail = detail


class ExportAbortedError(Exception):
    """Raised inside a handler when the consumer is shutting down; the kit naks the request."""


def describe_unexpected(err: BaseException) -> str:
    """The part of an unexpected error that may travel to the worker.

    Its class and, when it has one, its code; never the message, which can quote a value (a
    driver error can echo a row).
    """
    code = getattr(err, "sqlstate", None) or getattr(err, "code", None)
    name = type(err).__name__
    return f"{name} ({code})" if isinstance(code, str | int) and code != "" else name
