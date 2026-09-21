"""Enrollment parsing, pinned against saved HTML and workbook fixtures.

These are the highest-value tests in the repo. The parsing rules are somebody
else's markup and sheet layouts, so the only way to know a change broke them
is to have written down what they currently do. Nothing here touches the
network.
"""

from __future__ import annotations

import pathlib

import pandas as pd
import pytest

from owcdata.errors import NoSourceFilesFound, WorkbookReshapeError
from owcdata.pipelines.enrollment import scrape


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
def test_discovery_finds_every_primary_and_pairs_companions(serve_fixtures, enrollment_env):
    url = serve_fixtures("page.html")
    records, companions = scrape.discover_enrollment_files(url)

    titles = sorted(r["title"] for r in records)
    # FY2018/2019 is absent on purpose: its workbook matches no known sheet
    # signature, so discovery rejects it and records a skip (see
    # test_unrecognized_workbook_records_a_skip).
    assert titles == [
        "FY 2022/2023 — School Site Totals w/Ethnicity and Gender",
        "FY 2023/2024 — School Site Totals w/Ethnicity and Gender",
        "FY 2023/2024 — School Totals by Race",
    ], titles

    # The companion is keyed by fiscal year, which is how it gets paired to
    # the primary it backfills.
    assert "2022-2023" in companions
    assert companions["2022-2023"]["sheet"] == "ALL sites"

    # A "School Site Totals" with no primary in its section is never a source.
    assert not any("orphan" in r["url"] for r in records)


def test_discovery_ignores_anchors_outside_the_grid_wrapper(serve_fixtures, enrollment_env):
    """Container scoping is the whole reason locate_containers looks two levels
    deep. A decoy div with the right class outside the wrapper must not match."""
    url = serve_fixtures("page.html")
    records, _ = scrape.discover_enrollment_files(url)
    assert not any("decoy" in r["url"] for r in records)
    assert not scrape.WARNINGS, "the fixture page has a proper wrapper"


def test_exact_normalized_match_keeps_the_two_li_patterns_apart():
    """ "School Site Totals" must not also match "School Site Totals
    w/Ethnicity and Gender" — the page links both and they are different
    downloads."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(
        '<ul><li><a href="a">School Site Totals w/Ethnicity and Gender</a></li>'
        '<li><a href="b">School Site Totals</a></li>'
        '<li><a href="c">Click here</a></li></ul>',
        "html.parser",
    )
    kinds = [scrape.classify_anchor(a) for a in soup.find_all("a")]
    assert kinds == ["school_ethgen_li", "school_site_li", "click_here"]


@pytest.mark.parametrize(
    "heading,expected",
    [
        ("FY 2023/2024", "2023-2024"),
        ("FY 2024", "2023-2024"),
        ("FY24", "2023-2024"),
        ("Other Resources", None),
        (None, None),
    ],
)
def test_fiscal_year_parsing(heading, expected):
    assert scrape.parse_fiscal_year(heading) == expected


def test_unrecognized_workbook_records_a_skip(serve_fixtures, enrollment_env):
    """A workbook whose sheets match no known signature is a recorded failure,
    not a silent continue."""
    url = serve_fixtures("page.html")
    scrape.discover_enrollment_files(url)
    kinds = {s["kind"] for s in scrape.SKIPS}
    assert "no_matching_sheet" in kinds, scrape.SKIPS


def test_missing_companion_records_unreachable_skip(serve_fixtures, enrollment_env):
    """FY2023/2024 links a companion that 404s. The primary still processes,
    but the failed download is recorded."""
    url = serve_fixtures("page.html")
    scrape.discover_enrollment_files(url)
    details = " ".join(s["detail"] for s in scrape.SKIPS if s["kind"] == "source_file_unreachable")
    assert "fy2024_school_site_totals_missing.xlsx" in details


# ---------------------------------------------------------------------------
# Reshaping
# ---------------------------------------------------------------------------
def test_reshape_abbreviated_convention(serve_fixtures, enrollment_env):
    url = serve_fixtures("page.html")
    records, _ = scrape.discover_enrollment_files(url)
    record = next(r for r in records if r["pattern"] == "click_here")
    tidy = scrape.reshape_workbook(record)

    assert list(tidy.columns) == [
        "Year",
        "County",
        "District",
        "School",
        "Race",
        "Gender",
        "Grade",
        "Total",
    ]
    # 3 schools x 14 race/gender columns
    assert len(tidy) == 42
    assert set(tidy["Race"]) == {
        "Hispanic or Latino",
        "American Indian or Alaska Native",
        "Asian",
        "Black or African American",
        "Native Hawaiian or Other Pacific Islander",
        "White",
        "Two or more races",
    }
    assert set(tidy["Gender"]) == {"Male", "Female"}
    # No SchoolYear column in this workbook, so the FY heading supplies it.
    assert set(tidy["Year"]) == {"2023-2024"}


def test_reshape_verbose_v1_prefers_grade_code_over_prose_grade(serve_fixtures, enrollment_env):
    url = serve_fixtures("page.html")
    records, _ = scrape.discover_enrollment_files(url)
    record = next(r for r in records if "fy2024_school_site_ethgen" in r["url"])
    tidy = scrape.reshape_workbook(record)

    # "3H" -> Pre-Kindergarten proves the Grade Code column won; the prose
    # "Kindergarten level" column would have become "Other".
    assert set(tidy["Grade"]) == {"Pre-Kindergarten", "Kindergarten", "5th Grade"}
    assert "Other" not in set(tidy["Grade"])
    # The workbook's own SchoolYear=2024 becomes 2023-2024.
    assert set(tidy["Year"]) == {"2023-2024"}


def test_reshape_verbose_v2_backfills_blank_location_from_companion(
    serve_fixtures, enrollment_env, capsys
):
    url = serve_fixtures("page.html")
    records, companions = scrape.discover_enrollment_files(url)
    record = next(r for r in records if "wave" in r["url"])
    companion = companions[record["fiscal_year"]]

    blank_before = pd.read_excel(
        record["local_path"], sheet_name=record["sheet"], header=record["header_row"]
    )
    assert blank_before["County"].isna().any() or (blank_before["County"] == "").any()

    tidy = scrape.reshape_workbook(record, companion=companion)
    # School 1 / code 101 gets CREEK from the companion; nothing is guessed.
    filled = tidy[tidy["School"] == "School 1"]["County"].unique().tolist()
    assert filled == ["CREEK"], filled
    assert "Backfilled" in capsys.readouterr().out


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("3H", "Pre-Kindergarten"),
        ("3F", "Pre-Kindergarten"),
        ("PK", "Pre-Kindergarten"),
        ("K", "Kindergarten"),
        ("KG", "Kindergarten"),
        (1, "1st Grade"),
        (2, "2nd Grade"),
        (3, "3rd Grade"),
        (4, "4th Grade"),
        (11, "11th Grade"),
        (12, "12th Grade"),
        (13, "Other"),
        ("OHP", "Other"),
        ("AE", "Other"),
    ],
)
def test_format_grade(raw, expected):
    assert scrape.format_grade(raw) == expected


@pytest.mark.parametrize(
    "raw,expected",
    [
        (2024, "2023-2024"),
        ("2024", "2023-2024"),
        ("2024.0", "2023-2024"),
        ("2023-2024", "2023-2024"),
        ("not a year", "not a year"),
    ],
)
def test_clean_year(raw, expected):
    assert scrape.clean_year(raw) == expected


# ---------------------------------------------------------------------------
# main(): exit-code behavior — the single most important check in the project
# ---------------------------------------------------------------------------
def test_full_run_writes_merged_csv_and_reports_skips(serve_fixtures, enrollment_env):
    """scrape.main() reports what happened; run.py decides the exit code.

    The merged CSV is still written — partial output is better than none for
    diagnosis — but the skip is on the result, so the run cannot be reported
    as a success.
    """
    serve_fixtures("page.html")
    result = scrape.main()

    assert result.reshaped_files == 3
    assert result.merged_rows == 126  # 3 workbooks x 3 schools x 14 race/gender
    assert not result.short_circuited
    # The fixture page includes one unparseable workbook and one 404 companion.
    assert {s["kind"] for s in result.skips} == {"no_matching_sheet", "source_file_unreachable"}

    assert result.merged_path is not None
    df = pd.read_csv(result.merged_path)
    assert len(df) == 126
    assert list(df.columns) == [
        "Year",
        "County",
        "District",
        "School",
        "Race",
        "Gender",
        "Grade",
        "Total",
    ]
    assert set(df["Year"]) == {"2023-2024", "2022-2023"}


def test_run_turns_recorded_skips_into_a_nonzero_exit(serve_fixtures, enrollment_env, settings):
    """The wrapper is what converts a recorded skip into a failed run."""
    from owcdata.config import PipelinesConfig
    from owcdata.pipelines.enrollment import run as enrollment_run

    url = serve_fixtures("page.html")
    config = PipelinesConfig.load()
    config.enrollment.page_url = url
    config.enrollment.download_delay_seconds = 0.0

    with pytest.raises(WorkbookReshapeError) as exc:
        enrollment_run.run(settings, config, data_dir=enrollment_env)
    assert exc.value.event == "workbook_reshape_skipped"
    assert exc.value.exit_code != 0


def test_redesigned_page_raises_no_source_files_found(serve_fixtures, enrollment_env):
    """The most likely failure this pipeline will ever have.

    The original printed "No matching files were found on the page. Nothing to
    do." and returned normally, which under a scheduler is indistinguishable
    from success.
    """
    serve_fixtures("page_redesigned.html")
    with pytest.raises(NoSourceFilesFound) as exc:
        scrape.main()
    assert exc.value.event == "no_source_files_found"
    assert exc.value.exit_code != 0


def test_cache_short_circuits_on_second_run(serve_fixtures, enrollment_env, monkeypatch):
    """Run twice; the second run must find everything cached and not rebuild.

    This is the behavior the GCS volume mount exists to preserve — without it
    the pipeline re-downloads Oklahoma's entire back catalogue every month.
    """
    serve_fixtures("page.html")

    first = scrape.main()
    assert not first.short_circuited
    assert first.merged_path is not None
    first_csv = pathlib.Path(first.merged_path).read_bytes()
    sources = sorted(p.name for p in (enrollment_env / "data_sources").glob("*.xlsx"))
    assert sources, "originals must be cached in data_sources/"

    # Second run: every found record is cached, so main() short-circuits and
    # leaves the merged CSV byte-identical rather than rebuilding it.
    second = scrape.main()
    assert second.short_circuited, "second run rebuilt instead of using the cache"
    assert all(r["cached"] for r in second.records), [
        (r["title"], r["cached"]) for r in second.records
    ]
    assert second.merged_path is not None
    assert pathlib.Path(second.merged_path).read_bytes() == first_csv


# ---------------------------------------------------------------------------
# Every failure records a manifest row
# ---------------------------------------------------------------------------
def test_a_publish_failure_still_records_a_manifest_row(
    enrollment_env, settings, monkeypatch, tmp_path
):
    """Regression: a failure AFTER the scrape must not vanish from the manifest.

    An earlier version wrapped only scrape.main() in try/except, so a
    permission error during publish wrote no row at all. Cloud Run then
    retried, the retry short-circuited on the now-warm cache and recorded
    success_no_change, and the execution reported success — with the real
    failure invisible to the freshness alert that reads this table.

    Stubs the scrape so the test is about the error-handling structure and not
    about parsing (which is covered above).
    """
    from owcdata.config import PipelinesConfig
    from owcdata.core.manifest import ManifestWriter
    from owcdata.pipelines.enrollment import run as enrollment_run

    merged = tmp_path / "primary_enrollment_data.csv"
    merged.write_text(
        "Year,County,District,School,Race,Gender,Grade,Total\n2023-2024,TULSA,D,S,White,Male,1st Grade,5\n"
    )

    config = PipelinesConfig.load()
    config.enrollment.page_url = "https://example.test/page.html"
    config.enrollment.download_delay_seconds = 0.0

    def fake_main():
        return scrape.RunResult(
            records=[{"title": "t", "cached": False}],
            merged_path=str(merged),
            merged_rows=1,
            reshaped_files=1,
            short_circuited=False,
            skips=[],
            warnings=[],
        )

    def boom(*_a, **_k):
        raise RuntimeError("403 denied while publishing")

    monkeypatch.setattr(enrollment_run, "_check_robots", lambda *_a, **_k: None)
    monkeypatch.setattr(scrape, "main", fake_main)
    monkeypatch.setattr(enrollment_run, "land_parquet", boom)

    written: list[dict] = []

    class RecordingManifest(ManifestWriter):
        def __init__(self) -> None:
            super().__init__(bq=None, local_path=None)

        def write(self, record) -> None:  # type: ignore[override]
            written.append(record.to_row())

        def previous_successful(self, pipeline, dataset):  # type: ignore[override]
            return None

    with pytest.raises(RuntimeError, match="403 denied"):
        enrollment_run.run(
            settings,
            config,
            bq=object(),  # non-None so the publish path is taken
            manifest=RecordingManifest(),
            data_dir=enrollment_env,
        )

    assert written, "a publish failure wrote no manifest row at all"
    assert written[-1]["status"] == "failed"
    assert "403 denied" in written[-1]["error"]


def test_a_failure_records_exactly_one_manifest_row(serve_fixtures, enrollment_env, settings):
    """The skip path and the outer handler must not both write."""
    from owcdata.config import PipelinesConfig
    from owcdata.core.manifest import ManifestWriter
    from owcdata.pipelines.enrollment import run as enrollment_run

    url = serve_fixtures("page.html")
    config = PipelinesConfig.load()
    config.enrollment.page_url = url
    config.enrollment.download_delay_seconds = 0.0

    written: list[dict] = []

    class RecordingManifest(ManifestWriter):
        def __init__(self) -> None:
            super().__init__(bq=None, local_path=None)

        def write(self, record) -> None:  # type: ignore[override]
            written.append(record.to_row())

    with pytest.raises(WorkbookReshapeError):
        enrollment_run.run(settings, config, manifest=RecordingManifest(), data_dir=enrollment_env)

    failed = [r for r in written if r["status"] == "failed"]
    assert len(failed) == 1, f"expected exactly one failed row, got {len(failed)}"


def test_short_circuit_records_the_published_row_count_not_zero(
    enrollment_env, settings, monkeypatch
):
    """A short-circuit means "nothing new to publish", not "the table is empty".

    Recording 0 made owc_ops.dataset_freshness tell stakeholders the
    enrollment table held no rows when it held 1.4M. The count comes from
    table metadata, so it costs nothing.
    """
    from owcdata.config import PipelinesConfig
    from owcdata.core.manifest import ManifestWriter
    from owcdata.pipelines.enrollment import run as enrollment_run

    config = PipelinesConfig.load()
    config.enrollment.page_url = "https://example.test/page.html"

    monkeypatch.setattr(enrollment_run, "_check_robots", lambda *_a, **_k: None)
    monkeypatch.setattr(
        scrape,
        "main",
        lambda: scrape.RunResult(
            records=[{"cached": True}],
            merged_path=None,
            short_circuited=True,
            skips=[],
            warnings=[],
        ),
    )

    class FakeBQ:
        marts = "owc_marts"

        def table_row_count(self, dataset, table):
            return 1_435_546

    written: list[dict] = []

    class RecordingManifest(ManifestWriter):
        def __init__(self) -> None:
            super().__init__(bq=None, local_path=None)

        def write(self, record) -> None:  # type: ignore[override]
            written.append(record.to_row())

    outcome = enrollment_run.run(
        settings,
        config,
        bq=FakeBQ(),
        manifest=RecordingManifest(),
        data_dir=enrollment_env,
    )

    assert outcome.short_circuited
    assert written[-1]["status"] == "success_no_change"
    assert written[-1]["row_count"] == 1_435_546, "short-circuit recorded the wrong count"


def test_short_circuit_leaves_row_count_unset_when_marts_has_no_table_yet(
    enrollment_env, settings, monkeypatch
):
    """First ever run: better to record nothing than to guess."""
    from owcdata.config import PipelinesConfig
    from owcdata.core.manifest import ManifestWriter
    from owcdata.pipelines.enrollment import run as enrollment_run

    config = PipelinesConfig.load()
    config.enrollment.page_url = "https://example.test/page.html"

    monkeypatch.setattr(enrollment_run, "_check_robots", lambda *_a, **_k: None)
    monkeypatch.setattr(
        scrape,
        "main",
        lambda: scrape.RunResult(
            records=[{"cached": True}],
            merged_path=None,
            short_circuited=True,
            skips=[],
            warnings=[],
        ),
    )

    class MissingTableBQ:
        marts = "owc_marts"

        def table_row_count(self, dataset, table):
            raise RuntimeError("404 Not found: Table owc_marts.enrollment_primary")

    written: list[dict] = []

    class RecordingManifest(ManifestWriter):
        def __init__(self) -> None:
            super().__init__(bq=None, local_path=None)

        def write(self, record) -> None:  # type: ignore[override]
            written.append(record.to_row())

    enrollment_run.run(
        settings,
        config,
        bq=MissingTableBQ(),
        manifest=RecordingManifest(),
        data_dir=enrollment_env,
    )
    assert written[-1]["status"] == "success_no_change"
    assert written[-1]["row_count"] is None
