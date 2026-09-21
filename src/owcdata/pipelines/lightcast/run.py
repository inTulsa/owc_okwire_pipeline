"""The lightcast pipeline: Snowflake → Parquet → GCS → BigQuery.

No query is rewritten. ``sql/owc/`` is verbatim, and ``--limit`` wraps the
text in memory only.

The one behavioral change from the original pipeline is the one that matters:
**a failed dataset fails the run.** The original caught every exception per
SQL file, printed it, and exited 0. Under a scheduler that means every alert
is permanently green.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pyarrow as pa
import pyarrow.parquet as pq

from owcdata.config import PipelinesConfig, Settings
from owcdata.core.manifest import ManifestWriter, RunRecord
from owcdata.core.publish import land_parquet
from owcdata.core.sinks import Sink, build_sink
from owcdata.errors import ExtractError, PipelineError
from owcdata.logging import get_logger
from owcdata.pipelines.lightcast.datasets import Dataset, resolve, shard
from owcdata.pipelines.lightcast.snowflake import arrow_batches, connect

log = get_logger(__name__)

PIPELINE = "lightcast"

# Arrow batches are buffered to about this much before being written as one
# Parquet row group. This is the number that keeps a multi-GB dataset inside a
# 2 GiB task: peak memory tracks one row group, not one result set.
#
# Measured on this code (see tests/unit/test_parquet_stream.py): peak RSS is
# flat in result size — a 1.6 GB and a 3.2 GB result set both peak the same —
# and the level is set by this constant. 128 MiB peaks around 440 MB, 64 MiB
# around 290 MB, and 32 MiB buys nothing further because the floor is pyarrow
# and the interpreter. 64 MiB it is: ~7x headroom inside a 2 GiB task.
ROW_GROUP_TARGET_BYTES = 64 * 1024 * 1024


@dataclass
class ExtractOutcome:
    rows: int
    bytes_written: int
    query_id: str
    uri: str
    schema: pa.Schema


def _write_parquet_stream(result: Any, fh: Any) -> tuple[int, pa.Schema]:
    """Stream Arrow batches into ``fh`` as Parquet. Returns (rows, schema).

    Batches are grouped up to ``ROW_GROUP_TARGET_BYTES`` before being written,
    so the file gets a handful of well-sized row groups instead of one tiny
    row group per Snowflake result chunk — while still never holding more than
    one row group in memory.
    """
    writer: pq.ParquetWriter | None = None
    schema: pa.Schema | None = None
    pending: list[pa.RecordBatch] = []
    pending_bytes = 0
    rows = 0

    def flush() -> None:
        nonlocal pending, pending_bytes
        if pending and writer is not None:
            writer.write_table(pa.Table.from_batches(pending))
        pending = []
        pending_bytes = 0

    try:
        for batch in result.batches:
            if writer is None:
                schema = batch.schema
                writer = pq.ParquetWriter(fh, schema, compression="snappy")
            pending.append(batch)
            pending_bytes += batch.nbytes
            rows += batch.num_rows
            if pending_bytes >= ROW_GROUP_TARGET_BYTES:
                flush()
        flush()

        if writer is None:
            # Zero rows: no batch to take a schema from, so fall back to the
            # cursor description and write a schema-only Parquet file. The
            # quality gate decides whether zero rows is acceptable.
            schema = result.schema()
            writer = pq.ParquetWriter(fh, schema, compression="snappy")
            writer.write_table(pa.Table.from_batches([], schema=schema))
    finally:
        if writer is not None:
            writer.close()

    assert schema is not None
    return rows, schema


def extract(
    conn: Any, dataset: Dataset, sink: Sink, *, run_id: str, limit: int | None
) -> ExtractOutcome:
    """Run one dataset's query and stream the result to ``sink`` as Parquet."""
    query = dataset.query(limit=limit)
    rel_path = f"{dataset.name}/run_id={run_id}/{dataset.name}.parquet"

    log.info("extract_started", dataset=dataset.name, limit=limit, target=sink.uri(rel_path))
    result = arrow_batches(conn, query)
    try:
        with sink.open_write(rel_path) as fh:
            rows, schema = _write_parquet_stream(result, fh)
            bytes_written = int(fh.tell()) if hasattr(fh, "tell") else 0
    finally:
        result.close()

    log.info(
        "extract_finished",
        dataset=dataset.name,
        rows=rows,
        bytes=bytes_written,
        query_id=result.query_id,
    )
    return ExtractOutcome(
        rows=rows,
        bytes_written=bytes_written,
        query_id=result.query_id,
        uri=sink.uri(rel_path),
        schema=schema,
    )


def run(
    settings: Settings,
    config: PipelinesConfig,
    *,
    group: str | None = None,
    dataset: str | None = None,
    limit: int | None = None,
    bq: Any | None = None,
    manifest: ManifestWriter | None = None,
) -> None:
    """Extract, and where a warehouse is configured, land the results.

    Raises ``PipelineError`` if any dataset fails. Every dataset is still
    attempted first — one broken query should not hide the state of the other
    40 — but the run does not end successfully.
    """
    lc = config.lightcast
    datasets = resolve(lc, group=group, dataset=dataset)
    mine = shard(datasets, settings.task_index, settings.task_count)

    log.info(
        "lightcast_run_started",
        run_id=settings.run_id,
        group=group or "all",
        datasets=[d.name for d in mine],
        task=f"{settings.task_index + 1}/{settings.task_count}",
        target=settings.target,
    )
    if not mine:
        # More tasks than datasets: a no-op task, not a failure.
        log.info("lightcast_no_datasets_for_task", task_index=settings.task_index)
        return

    sink = build_sink(settings, PIPELINE)
    manifest = manifest or ManifestWriter(
        bq=bq, local_path=settings.local_output_dir / "pipeline_runs.jsonl"
    )
    failures: list[tuple[str, str]] = []

    with connect(config_snowflake()) as conn:
        for ds in mine:
            record = RunRecord(
                run_id=settings.run_id,
                pipeline=PIPELINE,
                dataset=ds.name,
                group_name=ds.group,
                git_sha=settings.git_sha,
                env=settings.env,
            )
            try:
                outcome = extract(conn, ds, sink, run_id=settings.run_id, limit=limit)
                record.row_count = outcome.rows
                record.bytes = outcome.bytes_written
                record.source_query_id = outcome.query_id
                record.source_uri = outcome.uri

                if bq is not None:
                    previous = manifest.previous_successful(PIPELINE, ds.name)
                    landed = land_parquet(
                        bq,
                        table=ds.name,
                        source_uris=outcome.uri,
                        schema=_bq_schema(outcome.schema),
                        run_id=settings.run_id,
                        quality=lc.quality,
                        previous_run=previous,
                        # A row-limited smoke run would trip every drift check.
                        allow_empty=limit is not None,
                    )
                    record.row_count = landed.row_count
                    record.max_year = landed.max_year

                manifest.write(record.finish("success"))
            except Exception as exc:
                log.error("dataset_failed", dataset=ds.name, error=str(exc), exc_info=True)
                manifest.write(record.finish("failed", error=str(exc)))
                failures.append((ds.name, str(exc)))

    if failures:
        names = ", ".join(name for name, _ in failures)
        raise ExtractError(f"{len(failures)} of {len(mine)} dataset(s) failed: {names}") from None

    log.info("lightcast_run_finished", run_id=settings.run_id, datasets=len(mine))


def _bq_schema(arrow_schema: pa.Schema) -> list[Any]:
    from owcdata.core.sinks.bigquery import arrow_to_bq_schema

    return arrow_to_bq_schema(arrow_schema)


def config_snowflake() -> Any:
    """Snowflake settings, read from the environment at call time."""
    from owcdata.config import SnowflakeSettings

    try:
        return SnowflakeSettings()
    except Exception as exc:
        from owcdata.errors import ConfigError

        raise ConfigError(f"invalid Snowflake configuration: {exc}") from exc


__all__ = ["PIPELINE", "ExtractOutcome", "PipelineError", "extract", "run"]
