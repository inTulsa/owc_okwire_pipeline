"""Guards on the publish path.

The case these exist for: a `--limit N` smoke run is a deliberate truncation
of the real result. On a first run there is no prior-run baseline and most
datasets have no configured row count, so every count-based check passes — and
without a guard the truncated rows would be copied over the production marts
table, and its row count would be recorded as the baseline the next real run
is compared against.
"""

from __future__ import annotations

import pytest

from owcdata.config import QualityConfig
from owcdata.core.publish import _validate_and_publish
from owcdata.errors import QualityCheckError


class FakeBQ:
    """Records what would have been done to marts."""

    def __init__(self) -> None:
        self.project, self.staging, self.marts = "p", "owc_staging", "owc_marts"
        self.ops = "owc_ops"
        self.copies: list[str] = []

    def ref(self, dataset: str, table: str) -> str:
        return f"{self.project}.{dataset}.{table}"

    def copy_to_marts(self, table: str) -> None:
        self.copies.append(table)


CFG = QualityConfig(
    row_count_drift_pct=20.0,
    known_row_counts={"dim_area": 78},
    not_null={"dim_area": ["AREAID"]},
)


def land(bq: FakeBQ, *, rows: int, row_limited: bool, previous=None, max_year=None, nulls=0):
    return _validate_and_publish(
        bq,
        table="dim_area",
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


def test_a_row_limited_run_never_publishes():
    """The core guard: truncated rows must not reach owc_marts."""
    bq = FakeBQ()
    result = land(bq, rows=10, row_limited=True)
    assert not result.published
    assert bq.copies == [], "a --limit run copied truncated rows into marts"


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
    assert bq.copies == []


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


def test_publish_is_a_single_copy_job():
    """Publish is one free, atomic copy and nothing else.

    Two earlier designs each added a step that needed a permission
    roles/bigquery.dataEditor lacks: a pass-through authorized view (needed
    bigquery.datasets.update, ADR-009) and a pre-publish table snapshot
    (needed bigquery.tables.deleteSnapshot, ADR-010). Both are gone, and
    rollback now reloads the previous run's Parquet from GCS. If a future
    change reintroduces either, this fails.
    """
    from owcdata.core import publish as publish_mod

    bq = FakeBQ()
    publish_mod.publish(bq, table="dim_area")

    assert bq.copies == ["dim_area"]
    # FakeBQ implements only copy_to_marts. Anything else publish might try —
    # a snapshot, a view, a dataset ACL update — would raise AttributeError
    # rather than pass silently.
    for gone in ("snapshot", "ensure_authorized_view", "update_dataset"):
        assert not hasattr(bq, gone)


def test_bigquery_client_needs_no_custom_role_permissions():
    """Everything the client does must fit roles/bigquery.dataEditor + jobUser.

    The two methods named here each required a permission that predefined role
    omits, and each forced a custom role. Rollback is a load job instead.
    """
    import inspect

    from owcdata.core.sinks.bigquery import BigQueryClient

    params = inspect.signature(BigQueryClient.__init__).parameters
    assert "reporting_dataset" not in params
    for gone in ("ensure_authorized_view", "snapshot", "restore_from_snapshot"):
        assert not hasattr(BigQueryClient, gone), f"{gone} is back"
    # The replacement.
    assert hasattr(BigQueryClient, "restore_from_uri")
