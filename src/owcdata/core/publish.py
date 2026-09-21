"""LOAD → VALIDATE → PUBLISH: the path both pipelines converge on.

    staging load  (atomic, free)
      → measure   (one scan of staging)
      → validate  (blocks publish; staging survives for diffing)
      → snapshot  (near-free; makes rollback one command)
      → copy      (atomic, free, preserves schema and clustering)
      → authorize (the view PowerBI reads, so PowerBI needs no marts grant)

``land_parquet`` is the lightcast entry point and ``land_dataframe`` the
enrollment one. Everything after the load is identical, which is the reason
this lives in ``core/`` rather than in either pipeline.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from owcdata.config import QualityConfig
from owcdata.core.quality import measure_staging, run_checks
from owcdata.logging import get_logger

log = get_logger(__name__)


@dataclass
class LandResult:
    table: str
    row_count: int
    max_year: int | None = None
    snapshot: str | None = None
    published: bool = False


def publish(bq: Any, *, table: str, run_id: str) -> str | None:
    """Snapshot the current marts table, then replace it from staging."""
    snapshot = bq.snapshot(table=table, run_id=run_id)
    bq.copy_to_marts(table)
    bq.ensure_authorized_view(table)
    return snapshot


def _validate_and_publish(
    bq: Any,
    *,
    table: str,
    run_id: str,
    quality: QualityConfig,
    previous_run: dict[str, Any] | None,
    allow_empty: bool,
    measurement: dict[str, Any],
) -> LandResult:
    report = run_checks(
        dataset=table,
        row_count=measurement["row_count"],
        config=quality,
        previous_run=previous_run,
        max_year=measurement.get("max_year"),
        null_counts=measurement.get("null_counts"),
        allow_empty=allow_empty,
    )
    # Raises QualityCheckError, which exits non-zero. Staging is intentionally
    # left exactly as loaded so the failure can be investigated.
    report.raise_if_failed()

    snapshot = publish(bq, table=table, run_id=run_id)
    return LandResult(
        table=table,
        row_count=measurement["row_count"],
        max_year=measurement.get("max_year"),
        snapshot=snapshot,
        published=True,
    )


def land_parquet(
    bq: Any,
    *,
    table: str,
    source_uris: str | list[str],
    schema: list[Any] | None,
    run_id: str,
    quality: QualityConfig,
    previous_run: dict[str, Any] | None = None,
    allow_empty: bool = False,
) -> LandResult:
    """Load Parquet from GCS, validate, publish. The lightcast path."""
    bq.load_parquet(table=table, source_uris=source_uris, schema=schema)
    measurement = measure_staging(bq, table, quality.not_null.get(table, []))
    return _validate_and_publish(
        bq,
        table=table,
        run_id=run_id,
        quality=quality,
        previous_run=previous_run,
        allow_empty=allow_empty,
        measurement=measurement,
    )


def land_dataframe(
    bq: Any,
    *,
    table: str,
    df: Any,
    run_id: str,
    quality: QualityConfig,
    previous_run: dict[str, Any] | None = None,
    allow_empty: bool = False,
) -> LandResult:
    """Load a DataFrame, validate, publish. The enrollment path."""
    bq.load_dataframe(table=table, df=df)
    measurement = measure_staging(bq, table, quality.not_null.get(table, []))
    return _validate_and_publish(
        bq,
        table=table,
        run_id=run_id,
        quality=quality,
        previous_run=previous_run,
        allow_empty=allow_empty,
        measurement=measurement,
    )
