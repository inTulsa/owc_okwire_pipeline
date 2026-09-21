"""Sink path building and BigQuery schema derivation."""

from __future__ import annotations

import pyarrow as pa
import pytest

from owcdata.config import Settings
from owcdata.core.sinks import build_sink
from owcdata.core.sinks.bigquery import arrow_to_bq_schema, bq_type_for
from owcdata.core.sinks.local import LocalSink


def test_pipelines_get_separate_prefixes(tmp_path):
    """The prefix is load-bearing: IAM is scoped to it, so the enrollment job
    cannot write lightcast output and vice versa."""
    s = Settings(target="local", local_output_dir=tmp_path)
    assert build_sink(s, "lightcast").uri("x") != build_sink(s, "enrollment").uri("x")
    assert "lightcast" in build_sink(s, "lightcast").uri("x")


def test_local_sink_creates_parent_directories(tmp_path):
    sink = LocalSink(tmp_path)
    sink.write_bytes("a/b/c/d.parquet", b"data")
    assert (tmp_path / "a/b/c/d.parquet").read_bytes() == b"data"


@pytest.mark.parametrize("bad", ["../escape", "a/../../escape", "/etc/passwd"])
def test_local_sink_refuses_paths_that_escape_its_root(tmp_path, bad):
    with pytest.raises(ValueError, match="escapes sink root"):
        LocalSink(tmp_path).write_bytes(bad, b"x")


def test_upload_file_copies(tmp_path):
    src = tmp_path / "src.xlsx"
    src.write_bytes(b"workbook")
    sink = LocalSink(tmp_path / "out")
    sink.upload_file("source_files/src.xlsx", str(src))
    assert (tmp_path / "out/source_files/src.xlsx").read_bytes() == b"workbook"


@pytest.mark.parametrize(
    "arrow,expected",
    [
        (pa.int64(), "INT64"),
        (pa.int32(), "INT64"),
        (pa.float64(), "FLOAT64"),
        (pa.string(), "STRING"),
        (pa.large_string(), "STRING"),
        (pa.bool_(), "BOOL"),
        (pa.date32(), "DATE"),
        (pa.timestamp("us"), "TIMESTAMP"),
        (pa.decimal128(18, 2), "NUMERIC"),
        (pa.binary(), "BYTES"),
        # Unmapped types degrade to STRING rather than failing a load at 3am.
        (pa.list_(pa.int32()), "STRING"),
    ],
)
def test_arrow_to_bq_type_mapping(arrow, expected):
    assert bq_type_for(arrow) == expected


def test_schema_is_explicit_and_all_nullable():
    """Autodetect on a multi-file Parquet load infers from the alphabetically
    last file, so schemas are always passed explicitly. NULLABLE because
    Snowflake nullability does not survive the Arrow result faithfully, and a
    wrong REQUIRED fails the load instead of the quality gate."""
    schema = arrow_to_bq_schema(pa.schema([("A", pa.int64()), ("B", pa.string())]))
    assert [f.name for f in schema] == ["A", "B"]
    assert {f.mode for f in schema} == {"NULLABLE"}
