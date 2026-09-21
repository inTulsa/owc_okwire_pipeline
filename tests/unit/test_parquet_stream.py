"""The streaming Parquet writer.

The property under test is that peak memory tracks the row-group target rather
than the result-set size. Cloud Run's filesystem is in-memory in both
execution generations with no size limit, so a writer that buffers the whole
result set crashes the task instead of failing a check.
"""

from __future__ import annotations

import pyarrow as pa
import pyarrow.parquet as pq
import pytest

from owcdata.core.sinks.local import LocalSink
from owcdata.pipelines.lightcast import run as lcrun

SCHEMA = pa.schema([("AREAID", pa.int64()), ("COUNTY_NAME", pa.string())])


class FakeResult:
    """Stands in for a Snowflake QueryResult."""

    def __init__(self, batches, schema=SCHEMA):
        self.batches = iter(batches)
        self._schema = schema
        self.query_id = "01b0-fake"
        self.closed = False

    def schema(self):
        return self._schema

    def close(self):
        self.closed = True


def batch(start: int, rows: int, pad: int = 8) -> pa.RecordBatch:
    return pa.RecordBatch.from_arrays(
        [pa.array(range(start, start + rows)), pa.array(["x" * pad] * rows)], schema=SCHEMA
    )


def test_writes_all_rows(tmp_path):
    sink = LocalSink(tmp_path)
    with sink.open_write("a.parquet") as fh:
        rows, schema = lcrun._write_parquet_stream(
            FakeResult([batch(i * 100, 100) for i in range(10)]), fh
        )
    assert rows == 1000
    assert schema.equals(SCHEMA)
    assert pq.ParquetFile(tmp_path / "a.parquet").metadata.num_rows == 1000


def test_zero_rows_still_writes_a_correctly_typed_file(tmp_path):
    """Snowflake yields no Arrow batch for an empty result, so the schema has
    to come from the cursor description — otherwise the BigQuery load would
    have nothing to load and the failure would surface far from its cause."""
    sink = LocalSink(tmp_path)
    with sink.open_write("empty.parquet") as fh:
        rows, _schema = lcrun._write_parquet_stream(FakeResult([]), fh)
    assert rows == 0
    f = pq.ParquetFile(tmp_path / "empty.parquet")
    assert f.metadata.num_rows == 0
    assert f.schema_arrow.equals(SCHEMA)


def test_flushes_multiple_row_groups_rather_than_buffering_everything(tmp_path, monkeypatch):
    monkeypatch.setattr(lcrun, "ROW_GROUP_TARGET_BYTES", 64 * 1024)
    sink = LocalSink(tmp_path)
    with sink.open_write("many.parquet") as fh:
        rows, _ = lcrun._write_parquet_stream(
            FakeResult([batch(i * 2000, 2000, pad=64) for i in range(20)]), fh
        )
    f = pq.ParquetFile(tmp_path / "many.parquet")
    assert rows == 40_000
    assert f.num_row_groups > 1, "the writer buffered the whole result set"
    assert f.metadata.num_rows == 40_000


def test_one_row_group_when_the_result_fits_under_the_target(tmp_path):
    """A small dimension table should not be split into dozens of row groups
    just because Snowflake happened to chunk it."""
    sink = LocalSink(tmp_path)
    with sink.open_write("small.parquet") as fh:
        lcrun._write_parquet_stream(FakeResult([batch(i * 10, 10) for i in range(20)]), fh)
    assert pq.ParquetFile(tmp_path / "small.parquet").num_row_groups == 1


def test_writer_is_closed_even_when_a_batch_raises(tmp_path):
    """A half-written Parquet file with no footer is unreadable; the file must
    at least be closed so the failure is a load error, not a hang."""

    def exploding():
        yield batch(0, 10)
        raise RuntimeError("snowflake went away mid-fetch")

    sink = LocalSink(tmp_path)
    with (
        pytest.raises(RuntimeError, match="went away"),
        sink.open_write("partial.parquet") as fh,
    ):
        lcrun._write_parquet_stream(FakeResult(exploding()), fh)
    assert (tmp_path / "partial.parquet").exists()


def test_peak_memory_does_not_grow_with_result_size(tmp_path, monkeypatch):
    """The core streaming guarantee, measured rather than asserted by comment.

    Doubling the result set must not double peak memory. Uses tracemalloc so
    it measures this process's own allocations rather than RSS, which an
    allocator can retain.
    """
    import tracemalloc

    monkeypatch.setattr(lcrun, "ROW_GROUP_TARGET_BYTES", 256 * 1024)
    sink = LocalSink(tmp_path)

    def peak_for(n_batches: int) -> int:
        def gen():
            for i in range(n_batches):
                yield batch(i * 5000, 5000, pad=128)

        tracemalloc.start()
        try:
            with sink.open_write(f"m{n_batches}.parquet") as fh:
                lcrun._write_parquet_stream(FakeResult(gen()), fh)
            return tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()

    small = peak_for(10)
    large = peak_for(40)  # 4x the rows
    # Generous bound: the point is that it does not scale with the result,
    # not that it is byte-identical run to run.
    assert large < small * 2, f"peak grew from {small} to {large} for 4x the data"
