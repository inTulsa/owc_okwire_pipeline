"""Streaming Arrow → Parquet writing, shared by both pipelines.

Lives in ``core`` because it is not Snowflake-specific: the enrollment
pipeline streams its merged output through the same path, which is what gives
it the same per-run GCS artifact — and therefore the same rollback story — as
lightcast. See ADR-010.

The property that matters: peak memory tracks the row-group target, not the
result size. Cloud Run's filesystem is in-memory in both execution
generations with no size limit, so a writer that buffers a whole result set
crashes the task rather than failing a check.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

import pyarrow as pa
import pyarrow.parquet as pq

# Chunks are buffered to about this much before being written as one Parquet
# row group. Measured on this code: peak RSS is flat in result size — a 1.6 GB
# and a 3.2 GB result set peak the same — and the level is set by this value.
# 128 MiB peaks around 440 MB, 64 MiB around 290 MB, and 32 MiB buys nothing
# further because the floor is pyarrow and the interpreter.
ROW_GROUP_TARGET_BYTES = 64 * 1024 * 1024


def as_table(chunk: Any) -> pa.Table:
    """Normalize one result chunk to a ``pa.Table``.

    Snowflake's ``fetch_arrow_batches()`` is typed ``Iterator[Table]`` and its
    docstring says "Fetch Arrow Tables in batches" — despite the name, each
    item is a **Table**, not a RecordBatch. Accepting either is cheap and
    means this does not break if that changes, or if a caller passes batches.
    """
    if isinstance(chunk, pa.Table):
        return chunk
    if isinstance(chunk, pa.RecordBatch):
        return pa.Table.from_batches([chunk])
    # A pandas DataFrame, which is how the enrollment pipeline feeds this.
    return pa.Table.from_pandas(chunk, preserve_index=False)


def write_parquet_stream(
    chunks: Iterable[Any],
    fh: Any,
    *,
    fallback_schema: pa.Schema | None = None,
    target_bytes: int = ROW_GROUP_TARGET_BYTES,
) -> tuple[int, pa.Schema]:
    """Stream ``chunks`` into ``fh`` as Parquet. Returns (rows, schema).

    Chunks are grouped up to ``target_bytes`` before being written, so the file
    gets a handful of well-sized row groups instead of one tiny row group per
    source chunk — while never holding more than one row group in memory.

    ``fallback_schema`` is used when there are no chunks at all: Snowflake
    yields nothing for an empty result, and an empty Parquet file still needs
    correct columns for the BigQuery load to produce a correct empty table.
    """
    writer: pq.ParquetWriter | None = None
    schema: pa.Schema | None = None
    pending: list[pa.Table] = []
    pending_bytes = 0
    rows = 0

    def flush() -> None:
        nonlocal pending, pending_bytes
        if pending and writer is not None:
            writer.write_table(pending[0] if len(pending) == 1 else pa.concat_tables(pending))
        pending = []
        pending_bytes = 0

    try:
        for chunk in chunks:
            table = as_table(chunk)
            if writer is None:
                schema = table.schema
                writer = pq.ParquetWriter(fh, schema, compression="snappy")
            elif not table.schema.equals(schema):
                # Chunks from one query always agree; a mismatch means the
                # caller is mixing sources, which would silently drop columns.
                table = table.cast(schema)
            pending.append(table)
            pending_bytes += table.nbytes
            rows += table.num_rows
            if pending_bytes >= target_bytes:
                flush()
        flush()

        if writer is None:
            if fallback_schema is None:
                raise ValueError("no chunks and no fallback_schema to write")
            schema = fallback_schema
            writer = pq.ParquetWriter(fh, schema, compression="snappy")
            writer.write_table(pa.Table.from_batches([], schema=schema))
    finally:
        if writer is not None:
            writer.close()

    assert schema is not None
    return rows, schema
