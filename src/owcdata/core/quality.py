"""The quality gate.

Checks run against **staging**, after the load and before the publish. That
ordering is deliberate: when a check fires, the suspect data is sitting in
``owc_staging`` where it can be queried and diffed against the previous run,
while ``owc_marts`` still holds the last known-good copy. Gating the load
instead would leave nothing to look at.

What these catch:

* ``row_count_drift`` / ``max_year_regressed`` — the smoke detector for the
  accepted risk that hardcoded year literals in the Lightcast SQL go stale.
  ``fact_regional_indicators.sql`` pins ``YEAR = 2025/2024/2023`` and the
  ``*_idx`` files pin a 2015 baseline; on a schedule those produce
  wrong-but-plausible numbers, which no amount of not-null checking would
  notice. Comparing against the previous run does.
* ``known_row_count`` — literal counts already known to be true, e.g.
  ``dim_area = 79``.
* ``not_null`` — columns that must never be null in a published table.
* ``empty_result`` — zero rows. For all 41 Lightcast datasets that means a
  break, so it fails unless the dataset is explicitly allowed to be empty.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from owcdata.config import QualityConfig
from owcdata.errors import QualityCheckError
from owcdata.logging import get_logger

log = get_logger(__name__)


@dataclass
class Check:
    name: str
    passed: bool
    detail: str
    observed: Any = None
    expected: Any = None

    def __str__(self) -> str:
        return f"{'PASS' if self.passed else 'FAIL'} {self.name}: {self.detail}"


@dataclass
class QualityReport:
    dataset: str
    checks: list[Check] = field(default_factory=list)

    def add(self, check: Check) -> Check:
        self.checks.append(check)
        return check

    @property
    def failures(self) -> list[Check]:
        return [c for c in self.checks if not c.passed]

    @property
    def passed(self) -> bool:
        return not self.failures

    def raise_if_failed(self) -> None:
        """Log every failure as ``quality_check_failed``, then raise.

        Alert #4 is a log-based metric on that exact event string, so each
        failure is emitted individually rather than rolled into the exception
        message — a run that fails three checks should show as three.
        """
        if self.passed:
            return
        for check in self.failures:
            log.error(
                "quality_check_failed",
                dataset=self.dataset,
                check=check.name,
                detail=check.detail,
                observed=check.observed,
                expected=check.expected,
            )
        raise QualityCheckError(
            f"{self.dataset}: {len(self.failures)} quality check(s) failed: "
            + "; ".join(c.detail for c in self.failures)
        )


def _drifted(current: int, previous: int, allowed_pct: float) -> tuple[bool, float]:
    if previous == 0:
        # No meaningful percentage against a zero baseline; any rows at all
        # are an improvement, and zero-to-zero is caught by the empty check.
        return (False, 0.0)
    pct = abs(current - previous) / previous * 100.0
    return (pct > allowed_pct, pct)


def run_checks(
    *,
    dataset: str,
    row_count: int,
    config: QualityConfig,
    previous_run: dict[str, Any] | None = None,
    max_year: int | None = None,
    null_counts: dict[str, int] | None = None,
    allow_empty: bool = False,
) -> QualityReport:
    """Evaluate every configured check. Pure — takes measurements, returns a report."""
    report = QualityReport(dataset=dataset)

    # -- empty result ------------------------------------------------------
    if not allow_empty:
        report.add(
            Check(
                name="empty_result",
                passed=row_count > 0,
                detail=(f"{dataset} returned 0 rows" if row_count == 0 else f"{row_count} rows"),
                observed=row_count,
                expected="> 0",
            )
        )

    # -- literal known counts ---------------------------------------------
    expected_count = config.known_row_counts.get(dataset)
    if expected_count is not None:
        report.add(
            Check(
                name="known_row_count",
                passed=row_count == expected_count,
                detail=f"{dataset} has {row_count} rows, expected exactly {expected_count}",
                observed=row_count,
                expected=expected_count,
            )
        )

    # -- drift vs the previous successful run -------------------------------
    if previous_run and previous_run.get("row_count") is not None:
        prev_rows = int(previous_run["row_count"])
        drifted, pct = _drifted(row_count, prev_rows, config.row_count_drift_pct)
        report.add(
            Check(
                name="row_count_drift",
                passed=not drifted,
                detail=(
                    f"{dataset} row count moved {pct:.1f}% "
                    f"({prev_rows} -> {row_count}), limit {config.row_count_drift_pct}%"
                ),
                observed=row_count,
                expected=f"{prev_rows} ±{config.row_count_drift_pct}%",
            )
        )

        prev_year = previous_run.get("max_year")
        if max_year is not None and prev_year is not None:
            # Only a regression fails. max(YEAR) going *up* is the pipeline
            # working; staying flat across a yearly dataset is normal within
            # a year. Going backwards means the query lost data.
            report.add(
                Check(
                    name="max_year_regressed",
                    passed=max_year >= int(prev_year),
                    detail=(f"{dataset} max(YEAR) went backwards: {prev_year} -> {max_year}"),
                    observed=max_year,
                    expected=f">= {prev_year}",
                )
            )
    else:
        log.info("quality_no_baseline", dataset=dataset, reason="first successful run")

    # -- not-null ----------------------------------------------------------
    for column in config.not_null.get(dataset, []):
        if null_counts is None or column not in null_counts:
            report.add(
                Check(
                    name="not_null",
                    passed=False,
                    detail=f"{dataset}.{column} is configured not-null but was not measured",
                    observed=None,
                    expected=0,
                )
            )
            continue
        nulls = null_counts[column]
        report.add(
            Check(
                name="not_null",
                passed=nulls == 0,
                detail=f"{dataset}.{column} has {nulls} null(s)",
                observed=nulls,
                expected=0,
            )
        )

    for check in report.checks:
        log.info(
            "quality_check",
            dataset=dataset,
            check=check.name,
            passed=check.passed,
            detail=check.detail,
        )
    return report


# ---------------------------------------------------------------------------
# Measurement against a staging table
# ---------------------------------------------------------------------------
def measure_staging(bq: Any, table: str, not_null_columns: list[str]) -> dict[str, Any]:
    """Row count, max(YEAR) if present, and null counts — in one query.

    One query rather than one per column: this scans staging, and a table
    with 15 not-null columns should not cost 15 scans.
    """
    schema = {f.name.upper(): f.name for f in bq.client.get_table(bq.ref(bq.staging, table)).schema}
    year_col = schema.get("YEAR")

    selects = ["COUNT(*) AS row_count"]
    if year_col:
        selects.append(f"SAFE_CAST(MAX(`{year_col}`) AS INT64) AS max_year")
    present = [c for c in not_null_columns if c.upper() in schema]
    for col in present:
        actual = schema[col.upper()]
        selects.append(f"COUNTIF(`{actual}` IS NULL) AS `null__{col}`")

    missing = [c for c in not_null_columns if c.upper() not in schema]
    if missing:
        # A configured column that no longer exists is itself a finding: the
        # query changed shape. Surfaced as an unmeasured not-null failure.
        log.warning("quality_column_missing", table=table, columns=missing)

    sql = f"SELECT {', '.join(selects)} FROM `{bq.ref(bq.staging, table)}`"
    row = bq.query_rows(sql)[0]

    return {
        "row_count": int(row["row_count"]),
        "max_year": row.get("max_year"),
        "null_counts": {c: int(row[f"null__{c}"]) for c in present},
    }
