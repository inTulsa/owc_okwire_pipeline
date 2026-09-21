"""The quality gate. These checks are what turn the accepted
hardcoded-year-literal risk into something detectable."""

from __future__ import annotations

import pytest

from owcdata.config import QualityConfig
from owcdata.core.quality import run_checks
from owcdata.errors import QualityCheckError

CFG = QualityConfig(
    row_count_drift_pct=20.0,
    known_row_counts={"dim_area": 79},
    not_null={"dim_area": ["AREAID"]},
)


def test_known_count_is_exact():
    ok = run_checks(dataset="dim_area", row_count=79, config=CFG, null_counts={"AREAID": 0})
    assert ok.passed
    bad = run_checks(dataset="dim_area", row_count=78, config=CFG, null_counts={"AREAID": 0})
    assert [c.name for c in bad.failures] == ["known_row_count"]


def test_zero_rows_fails_unless_explicitly_allowed():
    assert not run_checks(dataset="fact_jobs", row_count=0, config=CFG).passed
    assert run_checks(dataset="fact_jobs", row_count=0, config=CFG, allow_empty=True).passed


@pytest.mark.parametrize(
    "current,previous,should_fail",
    [
        (1000, 1000, False),
        (1150, 1000, False),
        (1250, 1000, True),
        (750, 1000, True),
        (850, 1000, False),
    ],
)
def test_row_count_drift_bounds(current, previous, should_fail):
    report = run_checks(
        dataset="fact_jobs",
        row_count=current,
        config=CFG,
        previous_run={"row_count": previous},
    )
    failed = any(c.name == "row_count_drift" for c in report.failures)
    assert failed is should_fail


def test_max_year_regression_fails_but_advancing_does_not():
    """A stale year literal shows up as max(YEAR) failing to advance or going
    backwards. Going backwards is unambiguous, so that is what fails."""
    back = run_checks(
        dataset="fact_emp",
        row_count=100,
        config=CFG,
        previous_run={"row_count": 100, "max_year": 2025},
        max_year=2024,
    )
    assert [c.name for c in back.failures] == ["max_year_regressed"]

    for year in (2025, 2026):
        forward = run_checks(
            dataset="fact_emp",
            row_count=100,
            config=CFG,
            previous_run={"row_count": 100, "max_year": 2025},
            max_year=year,
        )
        assert forward.passed


def test_first_run_has_no_baseline_and_passes():
    report = run_checks(dataset="fact_jobs", row_count=500, config=CFG, previous_run=None)
    assert report.passed
    assert not any(c.name == "row_count_drift" for c in report.checks)


def test_zero_baseline_does_not_produce_a_bogus_drift_failure():
    report = run_checks(
        dataset="fact_jobs", row_count=500, config=CFG, previous_run={"row_count": 0}
    )
    assert not any(c.name == "row_count_drift" and not c.passed for c in report.checks)


def test_not_null_violation_fails():
    report = run_checks(dataset="dim_area", row_count=79, config=CFG, null_counts={"AREAID": 3})
    assert [c.name for c in report.failures] == ["not_null"]


def test_unmeasured_not_null_column_fails_rather_than_passing_silently():
    """A configured column that vanished from the query is itself a finding.
    Treating "not measured" as "passed" is how a check quietly stops working."""
    report = run_checks(dataset="dim_area", row_count=79, config=CFG, null_counts={})
    assert [c.name for c in report.failures] == ["not_null"]


def test_raise_lists_every_failure():
    report = run_checks(
        dataset="dim_area",
        row_count=40,
        config=CFG,
        previous_run={"row_count": 79},
        null_counts={"AREAID": 2},
    )
    assert len(report.failures) == 3
    with pytest.raises(QualityCheckError) as exc:
        report.raise_if_failed()
    assert exc.value.event == "quality_check_failed"
    # The message carries each failure's detail, so an alert email says what
    # is wrong rather than just that something is.
    message = str(exc.value)
    assert "3 quality check(s) failed" in message
    assert "expected exactly 79" in message
    assert "moved 49.4%" in message
    assert "has 2 null(s)" in message
