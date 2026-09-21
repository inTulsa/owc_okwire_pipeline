"""Structured JSON logging for Cloud Logging.

Cloud Logging parses a single-line JSON object on stdout into ``jsonPayload``,
promoting a few reserved keys: ``severity`` drives the log level (so
``severity>=ERROR`` alert filters work) and ``message`` is what shows in the
console summary line. Everything else stays queryable as
``jsonPayload.<field>`` — which is how the log-based metrics find
``event="no_source_files_found"`` and friends.

Locally the same events render as human-readable console lines instead.
"""

from __future__ import annotations

import logging
import os
import sys
from typing import Any

import structlog

# structlog's level names -> the strings Cloud Logging recognizes.
_SEVERITY = {
    "critical": "CRITICAL",
    "exception": "ERROR",
    "error": "ERROR",
    "warn": "WARNING",
    "warning": "WARNING",
    "info": "INFO",
    "debug": "DEBUG",
    "notset": "DEFAULT",
}


def _severity(_logger: Any, method_name: str, event_dict: dict) -> dict:
    """Rename structlog's ``level`` to the ``severity`` key Cloud Logging reads."""
    event_dict.pop("level", None)
    event_dict["severity"] = _SEVERITY.get(method_name, "INFO")
    return event_dict


def _message(_logger: Any, _method_name: str, event_dict: dict) -> dict:
    """Copy the event name into ``message`` so the console line is readable.

    ``event`` is kept as well — the log-based metrics filter on it.
    """
    event = event_dict.get("event")
    if event is not None and "message" not in event_dict:
        event_dict["message"] = str(event)
    return event_dict


def configure(json_logs: bool | None = None, level: str = "INFO") -> None:
    """Install the logging pipeline. Idempotent; safe to call more than once.

    ``json_logs`` defaults to on whenever ``K_SERVICE`` or ``CLOUD_RUN_JOB`` is
    set, i.e. on Cloud Run, and off on a laptop.
    """
    if json_logs is None:
        json_logs = bool(os.getenv("CLOUD_RUN_JOB") or os.getenv("K_SERVICE"))

    shared: list[Any] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.TimeStamper(fmt="iso", utc=True),
    ]

    if json_logs:
        processors = [
            *shared,
            _severity,
            _message,
            structlog.processors.format_exc_info,
            structlog.processors.EventRenamer("event"),
            structlog.processors.JSONRenderer(),
        ]
    else:
        processors = [*shared, structlog.dev.ConsoleRenderer(colors=sys.stderr.isatty())]

    structlog.configure(
        processors=processors,
        wrapper_class=structlog.make_filtering_bound_logger(
            logging.getLevelNamesMapping().get(level.upper(), logging.INFO)
        ),
        logger_factory=structlog.PrintLoggerFactory(file=sys.stdout),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str = "owcdata") -> Any:
    return structlog.get_logger(name)


def bind_run(**kwargs: Any) -> None:
    """Bind run-scoped fields (run_id, pipeline, dataset) onto every later log."""
    structlog.contextvars.bind_contextvars(**kwargs)
