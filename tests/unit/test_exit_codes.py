"""Exit codes.

Per the design: "Break each deliberately and confirm non-zero exit — the
single most important check in this project." Both source pipelines caught
every exception, printed it, and exited 0. Cloud Run reads task success from
the exit code, so shipping that behavior would make every alert permanently
green.

These tests invoke the real CLI as a subprocess, because an in-process
assertion on an exception object would not prove what the shell sees.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from owcdata.errors import (
    ConfigError,
    NoSourceFilesFound,
    PipelineError,
    QualityCheckError,
    WorkbookReshapeError,
)

REPO = Path(__file__).resolve().parents[2]
CLI = [sys.executable, "-m", "owcdata.cli"]


def run_cli(*args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    full_env = {**os.environ, "OWC_TARGET": "local", **(env or {})}
    return subprocess.run(
        [*CLI, *args], cwd=REPO, capture_output=True, text=True, env=full_env, timeout=180
    )


# ---------------------------------------------------------------------------
# The taxonomy itself
# ---------------------------------------------------------------------------
def test_every_error_has_a_distinct_nonzero_exit_code():
    subclasses = _all_subclasses(PipelineError)
    codes = {c.exit_code for c in subclasses}
    assert 0 not in codes, "an error class with exit code 0 would report failure as success"
    # Distinct codes let the runbook map an exit code to a cause.
    assert len(codes) == len({c.exit_code for c in subclasses}), codes


def test_every_error_carries_an_event_string():
    """The log-based metrics match on these exact strings; an empty one would
    apply cleanly and then never fire."""
    for cls in _all_subclasses(PipelineError):
        assert cls.event and isinstance(cls.event, str), cls


def _all_subclasses(cls: type[PipelineError]) -> list[type[PipelineError]]:
    out: list[type[PipelineError]] = [cls]
    for sub in cls.__subclasses__():
        out.extend(_all_subclasses(sub))
    return out


@pytest.mark.parametrize(
    "cls,event",
    [
        (NoSourceFilesFound, "no_source_files_found"),
        (WorkbookReshapeError, "workbook_reshape_skipped"),
        (QualityCheckError, "quality_check_failed"),
        (ConfigError, "config_invalid"),
    ],
)
def test_alert_event_names_are_pinned(cls, event):
    """These strings are duplicated in Terraform log-metric filters. Renaming
    one here without renaming it there silently disables an alert."""
    assert cls.event == event


# ---------------------------------------------------------------------------
# End to end through the shell
# ---------------------------------------------------------------------------
def test_validate_exits_zero_on_a_good_repo():
    result = run_cli("validate")
    assert result.returncode == 0, result.stderr
    assert "All checks passed" in result.stdout


def test_unknown_pipeline_exits_nonzero():
    result = run_cli("run", "nonsense")
    assert result.returncode == ConfigError.exit_code


def test_unknown_dataset_exits_nonzero_without_touching_snowflake():
    """Resolution happens before the connection, so a typo costs nothing."""
    result = run_cli("run", "lightcast", "--dataset", "dim_aera")
    assert result.returncode == ConfigError.exit_code
    assert "snowflake_connecting" not in (result.stdout + result.stderr).lower()


def test_lightcast_without_credentials_exits_nonzero():
    """The original printed "Error connecting to Snowflake" and returned,
    exiting 0 — a scheduled run that never ran would have looked healthy."""
    result = run_cli(
        "run",
        "lightcast",
        "--dataset",
        "dim_area",
        env={"SNOWFLAKE_USER": "", "SNOWFLAKE_PASSWORD": ""},
    )
    assert result.returncode != 0
    assert "credentials missing" in (result.stdout + result.stderr)


def test_enrollment_rejects_lightcast_only_flags():
    result = run_cli("run", "enrollment", "--limit", "10")
    assert result.returncode == ConfigError.exit_code


def test_validate_fails_on_a_broken_config(tmp_path):
    bad = tmp_path / "pipelines.yml"
    bad.write_text("lightcast: {source_dir: sql/owc}\n")  # missing groups + enrollment
    result = run_cli("validate", "--pipelines-file", str(bad))
    assert result.returncode == 2
    assert "FAIL" in result.stderr


def test_validate_fails_when_a_sql_file_is_empty(tmp_path):
    """A zero-byte .sql file would otherwise run as an empty query."""
    sql_dir = tmp_path / "sql" / "owc"
    sql_dir.mkdir(parents=True)
    (sql_dir / "dim_broken.sql").write_text("")
    cfg = tmp_path / "pipelines.yml"
    cfg.write_text(
        f"""
lightcast:
  source_dir: {sql_dir.relative_to(tmp_path) if False else sql_dir}
  defaults: {{group: monthly}}
  groups:
    monthly: {{schedule: "0 6 1 * *"}}
enrollment:
  schedule: "0 7 5 * *"
  page_url: https://example.test/x.html
"""
    )
    result = run_cli("validate", "--pipelines-file", str(cfg))
    assert result.returncode == 2
    assert "is empty" in result.stderr


def test_scrape_module_run_directly_exits_nonzero_on_a_redesigned_page(tmp_path):
    """The carried-over script keeps working standalone, now with a real exit
    code — someone running `python scrape.py` out of habit still finds out."""
    script = REPO / "src/owcdata/pipelines/enrollment/scrape.py"
    harness = tmp_path / "harness.py"
    harness.write_text(
        f"""
import sys
sys.path.insert(0, {str(REPO / "src")!r})
sys.path.insert(0, {str(REPO / "tests")!r})
import urllib.parse, pathlib, requests
from owcdata.pipelines.enrollment import scrape
from owcdata.errors import PipelineError

FIX = pathlib.Path({str(REPO / "tests/fixtures/enrollment")!r})
def fake_get(url, headers=None, timeout=None, **kw):
    class R:
        def __init__(s, c): s.content, s.status_code = c, 200
        @property
        def text(s): return s.content.decode()
        def raise_for_status(s): pass
    return R((FIX / 'page_redesigned.html').read_bytes())
requests.get = fake_get

scrape.configure({str(tmp_path / "data")!r})
scrape.PAGE_URL = "https://example.test/page.html"
try:
    scrape.main()
except PipelineError as exc:
    print("FAILED:", exc)
    sys.exit(exc.exit_code)
print("exited 0 -- THIS IS THE BUG")
"""
    )
    result = subprocess.run(
        [sys.executable, str(harness)], capture_output=True, text=True, timeout=120
    )
    assert result.returncode == NoSourceFilesFound.exit_code, result.stdout + result.stderr
    assert "THIS IS THE BUG" not in result.stdout
    assert script.is_file()
