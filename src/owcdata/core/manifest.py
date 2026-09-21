"""``owc_ops.pipeline_runs`` — one row per dataset per run.

This table does three jobs:

1. It is the **freshness dead-man's-switch**. Cloud Monitoring's metric-absence
   condition caps at 23.5 hours, which covers a daily job and nothing else. A
   scheduled query over this table is the only thing that notices a quarterly
   scheduler that quietly stopped firing.
2. It is the **prior-run baseline** the quality gate compares against, which
   is what turns the accepted hardcoded-year risk into something detectable.
3. It is the **"is the data current?"** answer for non-technical stakeholders,
   who can read one table instead of asking someone to check Cloud Run.

``max_year`` is not in the original design sketch; alert #5 compares each run's
``max(YEAR)`` against the previous run's, and that value has to be persisted
somewhere to be compared.
"""

from __future__ import annotations

import datetime as dt
import json
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from owcdata.logging import get_logger

log = get_logger(__name__)

TABLE = "pipeline_runs"

# Mirrors infra/terraform/modules/platform/bigquery.tf. Kept here as the
# single source of truth for the writer; Terraform reads the same field list.
SCHEMA: list[tuple[str, str]] = [
    ("run_id", "STRING"),
    ("pipeline", "STRING"),
    ("dataset", "STRING"),
    ("group_name", "STRING"),
    ("status", "STRING"),
    ("row_count", "INT64"),
    ("bytes", "INT64"),
    ("max_year", "INT64"),
    ("source_query_id", "STRING"),
    ("source_uri", "STRING"),
    ("started_at", "TIMESTAMP"),
    ("finished_at", "TIMESTAMP"),
    ("duration_seconds", "FLOAT64"),
    ("git_sha", "STRING"),
    ("env", "STRING"),
    ("error", "STRING"),
]


def new_run_id() -> str:
    """A sortable, filesystem- and table-name-safe run id."""
    stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}_{uuid.uuid4().hex[:8]}"


@dataclass
class RunRecord:
    run_id: str
    pipeline: str
    dataset: str
    group_name: str = ""
    # running | success | success_no_change | success_limited | failed
    # success_limited is a --limit smoke run: deliberately excluded from
    # previous_successful() so it cannot become a quality baseline.
    status: str = "running"
    row_count: int | None = None
    bytes: int | None = None
    max_year: int | None = None
    source_query_id: str = ""
    source_uri: str = ""
    started_at: str = field(default_factory=lambda: dt.datetime.now(dt.UTC).isoformat())
    finished_at: str | None = None
    duration_seconds: float | None = None
    git_sha: str = "unknown"
    env: str = "dev"
    error: str = ""

    def finish(self, status: str, error: str = "") -> RunRecord:
        end = dt.datetime.now(dt.UTC)
        self.status = status
        self.finished_at = end.isoformat()
        self.duration_seconds = round(
            (end - dt.datetime.fromisoformat(self.started_at)).total_seconds(), 3
        )
        # Truncated because a Snowflake traceback can run to kilobytes and
        # this column is read in a console, not parsed.
        self.error = error[:4000]
        return self

    def to_row(self) -> dict[str, Any]:
        return asdict(self)


class ManifestWriter:
    """Writes run records. BigQuery when configured, JSONL on a laptop.

    Local runs get a manifest too, so ``make run`` exercises the same code
    path that production depends on rather than a branch that is never tested
    until it matters.
    """

    def __init__(self, bq: Any | None = None, local_path: Path | str | None = None) -> None:
        self.bq = bq
        self.local_path = Path(local_path) if local_path else None

    def write(self, record: RunRecord) -> None:
        row = record.to_row()
        if self.bq is not None:
            try:
                self.bq.insert_rows(self.bq.ops, TABLE, [row])
            except Exception as exc:
                # A manifest write must never be the reason a good run is
                # reported as failed — but it must be loud, because a silent
                # manifest gap disables the freshness alert.
                log.error("manifest_write_failed", error=str(exc), **row)
                return
        if self.local_path is not None:
            self.local_path.parent.mkdir(parents=True, exist_ok=True)
            with self.local_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(row) + "\n")
        log.info("run_recorded", **{k: v for k, v in row.items() if v not in (None, "")})

    def previous_successful(self, pipeline: str, dataset: str) -> dict[str, Any] | None:
        """The last successful run of ``dataset``, or None on the first ever run.

        ``run_id`` breaks ties because two tasks in one execution can land on
        the same ``finished_at`` to the microsecond.
        """
        if self.bq is None:
            return self._previous_from_local(pipeline, dataset)
        sql = f"""
            SELECT row_count, max_year, finished_at, run_id
            FROM `{self.bq.project}.{self.bq.ops}.{TABLE}`
            WHERE pipeline = @pipeline
              AND dataset = @dataset
              AND status = 'success'
              AND row_count IS NOT NULL
            ORDER BY finished_at DESC, run_id DESC
            LIMIT 1
        """
        rows = self.bq.query_rows(sql, {"pipeline": pipeline, "dataset": dataset})
        return rows[0] if rows else None

    def _previous_from_local(self, pipeline: str, dataset: str) -> dict[str, Any] | None:
        if self.local_path is None or not self.local_path.is_file():
            return None
        best: dict[str, Any] | None = None
        for line in self.local_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (
                row.get("pipeline") == pipeline
                and row.get("dataset") == dataset
                and row.get("status") == "success"
                and row.get("row_count") is not None
            ):
                best = row  # the file is append-only, so the last match is newest
        return best
