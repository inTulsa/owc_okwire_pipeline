"""Guards on the publish path.

The case these exist for: a `--limit N` smoke run is a deliberate truncation
of the real result. On a first run there is no prior-run baseline and most
datasets have no configured row count, so every count-based check passes — and
without a guard the truncated rows would be copied over the production marts
table, and its row count would be recorded as the baseline the next real run
is compared against.
"""

from __future__ import annotations

from typing import Any

import pytest

from owcdata.config import QualityConfig
from owcdata.core.publish import _validate_and_publish
from owcdata.errors import QualityCheckError


class FakeBQ:
    """Records what would have been done to marts."""

    def __init__(self) -> None:
        self.project, self.staging, self.marts = "p", "owc_staging", "owc_marts"
        self.ops, self.reporting = "owc_ops", "owc_reporting"
        self.snapshots: list[str] = []
        self.copies: list[str] = []
        self.views: list[str] = []

    def ref(self, dataset: str, table: str) -> str:
        return f"{self.project}.{dataset}.{table}"

    def snapshot(self, *, table: str, run_id: str, **_: Any) -> str:
        self.snapshots.append(table)
        return f"{self.project}.{self.ops}.{table}__{run_id}"

    def copy_to_marts(self, table: str) -> None:
        self.copies.append(table)

    def ensure_authorized_view(self, table: str) -> None:
        self.views.append(table)


CFG = QualityConfig(
    row_count_drift_pct=20.0,
    known_row_counts={"dim_area": 78},
    not_null={"dim_area": ["AREAID"]},
)


def land(bq: FakeBQ, *, rows: int, row_limited: bool, previous=None, max_year=None, nulls=0):
    return _validate_and_publish(
        bq,
        table="dim_area",
        run_id="r1",
        quality=CFG,
        previous_run=previous,
        allow_empty=row_limited,
        measurement={"row_count": rows, "max_year": max_year, "null_counts": {"AREAID": nulls}},
        row_limited=row_limited,
    )


def test_a_full_run_publishes():
    bq = FakeBQ()
    result = land(bq, rows=78, row_limited=False)
    assert result.published
    assert bq.copies == ["dim_area"]
    assert bq.views == ["dim_area"]


def test_a_row_limited_run_never_publishes():
    """The core guard: truncated rows must not reach owc_marts."""
    bq = FakeBQ()
    result = land(bq, rows=10, row_limited=True)
    assert not result.published
    assert bq.copies == [], "a --limit run copied truncated rows into marts"
    assert bq.snapshots == []
    assert bq.views == []


def test_row_limited_skips_the_known_row_count_check():
    """10 != 78 is expected under --limit and must not fail the run."""
    bq = FakeBQ()
    result = land(bq, rows=10, row_limited=True)
    assert result.row_count == 10


def test_row_limited_skips_drift_against_a_real_previous_run():
    bq = FakeBQ()
    result = land(bq, rows=10, row_limited=True, previous={"row_count": 78, "max_year": 2025})
    assert not result.published
    assert result.row_count == 10


def test_row_limited_still_enforces_not_null():
    """A limit changes how many rows come back, not the query's shape."""
    bq = FakeBQ()
    with pytest.raises(QualityCheckError, match="null"):
        land(bq, rows=10, row_limited=True, nulls=3)
    assert bq.copies == []


def test_a_full_run_still_enforces_the_known_count():
    bq = FakeBQ()
    with pytest.raises(QualityCheckError, match="expected exactly 78"):
        land(bq, rows=77, row_limited=False)
    assert bq.copies == [], "publish must be blocked when a check fails"


def test_failed_checks_leave_staging_alone_for_diffing():
    """Nothing in the failure path touches marts, so the last good data stands."""
    bq = FakeBQ()
    with pytest.raises(QualityCheckError):
        land(bq, rows=40, row_limited=False, previous={"row_count": 78})
    assert bq.snapshots == [] and bq.copies == [] and bq.views == []


def test_limited_runs_cannot_become_a_quality_baseline(tmp_path):
    """previous_successful() must ignore a success_limited row.

    Otherwise a smoke test poisons the baseline and the next real run fails
    its drift check against a truncated count.
    """
    from owcdata.core.manifest import ManifestWriter, RunRecord

    w = ManifestWriter(local_path=tmp_path / "runs.jsonl")
    w.write(
        RunRecord(run_id="r1", pipeline="lightcast", dataset="dim_area", row_count=78).finish(
            "success"
        )
    )
    w.write(
        RunRecord(run_id="r2", pipeline="lightcast", dataset="dim_area", row_count=10).finish(
            "success_limited"
        )
    )

    prev = w.previous_successful("lightcast", "dim_area")
    assert prev is not None
    assert prev["row_count"] == 78, "a --limit run became the baseline"
    assert prev["run_id"] == "r1"
