"""The run manifest — the freshness dead-man's-switch and quality baseline."""

from __future__ import annotations

import time

from owcdata.core.manifest import SCHEMA, ManifestWriter, RunRecord, new_run_id


def test_run_ids_are_unique():
    """Uniqueness comes from the random suffix; ordering comes from the
    timestamp prefix, which is what actually gets sorted on."""
    ids = [new_run_id() for _ in range(50)]
    assert len(set(ids)) == 50


def test_run_id_timestamp_prefix_sorts_chronologically():
    early = "20260101T000000Z_aaaaaaaa"
    late = "20260201T000000Z_00000000"
    assert early < late, "the prefix must dominate the random suffix when sorting"
    prefix = new_run_id().split("_")[0]
    assert len(prefix) == 16 and prefix.endswith("Z")


def test_run_id_is_safe_in_a_table_name():
    """run_id is interpolated into a GCS object path and read back from it.

    Keeping it to letters, digits and underscores means a run_id can never
    need escaping in a path, a table name, or a log filter.
    """
    assert new_run_id().replace("_", "").isalnum()


def test_finish_records_status_and_duration():
    r = RunRecord(run_id="r1", pipeline="lightcast", dataset="dim_area")
    time.sleep(0.01)
    r.finish("success")
    assert r.status == "success"
    assert r.finished_at is not None
    assert r.duration_seconds is not None
    assert r.duration_seconds > 0


def test_long_errors_are_truncated():
    r = RunRecord(run_id="r1", pipeline="lightcast", dataset="dim_area")
    r.finish("failed", error="x" * 10_000)
    assert len(r.error) == 4000


def test_row_matches_the_declared_schema():
    row = RunRecord(run_id="r1", pipeline="lightcast", dataset="dim_area").to_row()
    assert set(row) == {name for name, _ in SCHEMA}


def test_previous_successful_ignores_failures_and_takes_the_latest(tmp_path):
    path = tmp_path / "runs.jsonl"
    w = ManifestWriter(local_path=path)
    w.write(
        RunRecord(run_id="r1", pipeline="lightcast", dataset="dim_area", row_count=79).finish(
            "success"
        )
    )
    w.write(
        RunRecord(run_id="r2", pipeline="lightcast", dataset="dim_area", row_count=5).finish(
            "failed"
        )
    )
    w.write(
        RunRecord(run_id="r3", pipeline="lightcast", dataset="dim_area", row_count=80).finish(
            "success"
        )
    )

    prev = w.previous_successful("lightcast", "dim_area")
    assert prev is not None
    assert prev["run_id"] == "r3" and prev["row_count"] == 80
    assert w.previous_successful("lightcast", "other") is None
    assert w.previous_successful("enrollment", "dim_area") is None


def test_no_baseline_before_the_first_run(tmp_path):
    assert (
        ManifestWriter(local_path=tmp_path / "none.jsonl").previous_successful("lightcast", "x")
        is None
    )
