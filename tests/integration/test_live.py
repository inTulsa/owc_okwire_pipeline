"""Integration tests. ``pytest -m integration``; every one touches the network.

Run these against **dev**, never prod. The lightcast ones bill Lightcast's
warehouse, so they are row-limited.
"""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd
import pytest

from owcdata.config import PipelinesConfig, Settings

pytestmark = pytest.mark.integration

REPO = Path(__file__).resolve().parents[2]


def _require(*env_vars: str) -> None:
    missing = [v for v in env_vars if not os.getenv(v)]
    if missing:
        pytest.skip(f"needs {', '.join(missing)}")


# ---------------------------------------------------------------------------
# lightcast
# ---------------------------------------------------------------------------
def test_snowflake_query_returns_rows_with_a_limit(tmp_path):
    """A row-limited extract against the real share. Cheap on purpose."""
    _require("SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD")
    import pyarrow.parquet as pq

    from owcdata.core.sinks.local import LocalSink
    from owcdata.pipelines.lightcast.datasets import resolve
    from owcdata.pipelines.lightcast.run import config_snowflake, extract
    from owcdata.pipelines.lightcast.snowflake import connect

    config = PipelinesConfig.load()
    dataset = resolve(config.lightcast, dataset="dim_area")[0]
    sink = LocalSink(tmp_path)

    with connect(config_snowflake()) as conn:
        outcome = extract(conn, dataset, sink, run_id="itest", limit=100)

    assert outcome.rows > 0
    assert outcome.query_id, "the Snowflake query id must be recorded for the manifest"
    written = next(tmp_path.rglob("*.parquet"))
    assert pq.ParquetFile(written).metadata.num_rows == outcome.rows


def test_dim_area_has_the_known_79_rows():
    """The literal count the quality gate asserts. If this changes, either
    Oklahoma gained a county or the query broke."""
    _require("SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD")
    from owcdata.pipelines.lightcast.datasets import resolve
    from owcdata.pipelines.lightcast.run import config_snowflake
    from owcdata.pipelines.lightcast.snowflake import arrow_batches, connect

    config = PipelinesConfig.load()
    dataset = resolve(config.lightcast, dataset="dim_area")[0]
    with connect(config_snowflake()) as conn:
        result = arrow_batches(conn, dataset.query())
        rows = sum(b.num_rows for b in result.batches)
        result.close()

    expected = config.lightcast.quality.known_row_counts["dim_area"]
    assert rows == expected, (
        f"dim_area returned {rows} rows, pipelines.yml expects {expected}. "
        "Update known_row_counts only after confirming the change is real."
    )


def test_every_sql_file_compiles_against_snowflake():
    """Parse-only validation of all 41 queries with LIMIT 0 — catches a column
    renamed on Lightcast's side without extracting any data."""
    _require("SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD")
    from owcdata.pipelines.lightcast.datasets import resolve
    from owcdata.pipelines.lightcast.run import config_snowflake
    from owcdata.pipelines.lightcast.snowflake import connect

    config = PipelinesConfig.load()
    failures = []
    with connect(config_snowflake()) as conn:
        for dataset in resolve(config.lightcast):
            cursor = conn.cursor()
            try:
                cursor.describe(dataset.query(limit=1))
            except Exception as exc:
                failures.append(f"{dataset.name}: {exc}")
            finally:
                cursor.close()
    assert not failures, "\n".join(failures)


# ---------------------------------------------------------------------------
# enrollment
# ---------------------------------------------------------------------------
def test_live_scrape_finds_files_and_snapshots_the_page(tmp_path):
    """One live scrape. Also the only test that proves the real page still
    matches the selectors."""
    from owcdata.pipelines.enrollment import run as enrollment_run

    config = PipelinesConfig.load()
    settings = Settings(
        target="local",
        env="itest",
        run_id="itest",
        local_output_dir=tmp_path / "exports",
        enrollment_data_dir=tmp_path / "data",
    )
    outcome = enrollment_run.run(settings, config, data_dir=tmp_path / "data")

    assert outcome.rows > 0
    assert outcome.archived > 0
    snapshot = tmp_path / "exports/enrollment/page_snapshots/itest.html"
    assert snapshot.is_file() and snapshot.stat().st_size > 1000


def test_second_run_short_circuits_on_the_cache(tmp_path):
    """The whole risk of the GCS-volume-mount design. If this regresses, every
    monthly run re-downloads Oklahoma's entire back catalogue."""
    from owcdata.pipelines.enrollment import run as enrollment_run

    config = PipelinesConfig.load()
    settings = Settings(
        target="local",
        env="itest",
        run_id="itest-1",
        local_output_dir=tmp_path / "exports",
        enrollment_data_dir=tmp_path / "data",
    )
    first = enrollment_run.run(settings, config, data_dir=tmp_path / "data")
    assert not first.short_circuited
    assert first.merged_path is not None
    before = Path(first.merged_path).read_bytes()

    settings.run_id = "itest-2"
    second = enrollment_run.run(settings, config, data_dir=tmp_path / "data")
    assert second.short_circuited, "the cache did not short-circuit"
    assert second.merged_path is not None
    assert Path(second.merged_path).read_bytes() == before


# ---------------------------------------------------------------------------
# Parity with the original script
# ---------------------------------------------------------------------------
def test_reshape_is_identical_to_the_original_script(tmp_path):
    """Function-level parity over whatever real workbooks are cached locally.

    Run `make run PIPELINE=enrollment TARGET=local` first to populate the
    cache; this then proves the carried-over code produces the same frames the
    original did, workbook by workbook.
    """
    import contextlib
    import importlib.util
    import io
    import os as _os

    cache = REPO / ".owcdata-local/enrollment/data/data_sources"
    workbooks = (
        sorted(p for p in cache.glob("*") if p.suffix.lower() in (".xls", ".xlsx"))
        if cache.is_dir()
        else []
    )
    if not workbooks:
        pytest.skip("no cached workbooks; run `make run PIPELINE=enrollment TARGET=local` first")

    cwd = _os.getcwd()
    _os.chdir(tmp_path)  # the original makedirs("data") at import time
    try:
        spec = importlib.util.spec_from_file_location(
            "orig_enrollment", REPO / "tests/fixtures/primary_enrollment_data_script.original.py"
        )
        assert spec is not None and spec.loader is not None
        orig = importlib.util.module_from_spec(spec)
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(orig)
    finally:
        _os.chdir(cwd)

    from owcdata.pipelines.enrollment import scrape

    scrape.configure(REPO / ".owcdata-local/enrollment/data")

    compared = 0
    for path in workbooks:
        with pd.ExcelFile(path) as xls:
            sheet, header = scrape.find_sheet_by_column_signature(xls)
            pattern = "school_ethgen_li"
            if sheet is None:
                sheet = scrape.find_sheet_by_name(xls, scrape.SCHOOL_TOTALS_SHEET)
                header = scrape.find_header_row(xls, sheet) if sheet else None
                pattern = "click_here"
        if sheet is None or header is None:
            continue
        record = {
            "title": path.name,
            "url": str(path),
            "pattern": pattern,
            "sheet": sheet,
            "header_row": header,
            "local_path": str(path),
            "fiscal_year": None,
            "cached": True,
        }
        with contextlib.redirect_stdout(io.StringIO()):
            pd.testing.assert_frame_equal(
                scrape.reshape_workbook(dict(record)), orig.reshape_workbook(dict(record))
            )
        compared += 1

    assert compared == len(workbooks), f"only {compared} of {len(workbooks)} workbooks compared"


# ---------------------------------------------------------------------------
# GCS + BigQuery landing (dev)
# ---------------------------------------------------------------------------
def test_gcs_and_bigquery_round_trip():
    """Proves the streaming upload and the explicit-schema load agree."""
    _require("OWC_GCP_PROJECT", "OWC_GCS_RAW_BUCKET")
    import pyarrow as pa

    from owcdata.core.sinks.bigquery import BigQueryClient, arrow_to_bq_schema
    from owcdata.core.sinks.gcs import GCSSink
    from owcdata.pipelines.lightcast.run import _write_parquet_stream

    class Fake:
        def __init__(self, batches, schema):
            self.batches, self._s = iter(batches), schema

        def schema(self):
            return self._s

        def close(self):
            pass

    schema = pa.schema([("ID", pa.int64()), ("NAME", pa.string())])
    batch = pa.RecordBatch.from_arrays(
        [pa.array([1, 2, 3]), pa.array(["a", "b", "c"])], schema=schema
    )
    sink = GCSSink(os.environ["OWC_GCS_RAW_BUCKET"], prefix="itest")
    rel = "roundtrip/itest.parquet"
    with sink.open_write(rel) as fh:
        rows, written_schema = _write_parquet_stream(Fake([batch], schema), fh)
    assert rows == 3

    bq = BigQueryClient(os.environ["OWC_GCP_PROJECT"], location=os.getenv("OWC_BQ_LOCATION", "US"))
    loaded = bq.load_parquet(
        table="itest_roundtrip",
        source_uris=sink.uri(rel),
        schema=arrow_to_bq_schema(written_schema),
    )
    assert loaded == 3
