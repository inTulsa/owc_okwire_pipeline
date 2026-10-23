"""The enrollment pipeline: scrape → reshape → BigQuery.

All parsing lives in ``scrape.py`` and is unchanged. This module is the
infrastructure around it:

* **State.** ``scrape.configure()`` points the cache at a directory. In
  production that directory is a GCS bucket prefix mounted with FUSE, so
  ``os.path.exists()`` keeps working and the short-circuit-when-nothing-is-new
  behavior survives ephemeral containers with no change to the caching logic.
  Locally it points somewhere gitignored and separate, so a laptop run cannot
  corrupt the production cache.
* **Diagnosability.** The page HTML is snapshotted every run before parsing,
  and every freshly downloaded workbook is archived immutably. When parsing
  breaks on Oklahoma's schedule, that turns the investigation into a diff.
* **Real exit codes.** Zero files found, or any recorded skip, exits non-zero.
* **A newer school year elsewhere.** Oklahoma publishes on two pages. When
  ``newer_year_check_url`` is set, a school year there that the scrape did
  not collect fails the run rather than short-circuiting as "nothing new".
"""

from __future__ import annotations

import io
import re
import time
import urllib.parse
import urllib.robotparser
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from owcdata.config import PipelinesConfig, Settings
from owcdata.core.manifest import ManifestWriter, RunRecord
from owcdata.core.parquet import write_parquet_stream
from owcdata.core.publish import land_parquet
from owcdata.core.sinks import Sink, build_sink
from owcdata.errors import ExtractError, NewerSchoolYearNotScraped, WorkbookReshapeError
from owcdata.logging import get_logger
from owcdata.pipelines.enrollment import scrape

log = get_logger(__name__)

PIPELINE = "enrollment"


@dataclass
class EnrollmentOutcome:
    rows: int
    short_circuited: bool
    snapshot_uri: str | None
    archived: int
    merged_path: str | None


def _check_robots(page_url: str, user_agent: str) -> None:
    """Honor robots.txt. A fetch failure is not a disallow — proceed."""
    parts = urllib.parse.urlsplit(page_url)
    robots_url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, "/robots.txt", "", ""))
    parser = urllib.robotparser.RobotFileParser()
    parser.set_url(robots_url)
    try:
        parser.read()
    except Exception as exc:
        log.warning("robots_unreadable", url=robots_url, error=str(exc))
        return
    if not parser.can_fetch(user_agent, page_url):
        raise ExtractError(
            f"{robots_url} disallows fetching {page_url} for this user agent. "
            "Do not override without talking to the Oklahoma SDE first."
        )
    log.info("robots_allows_fetch", url=robots_url)


def _install_hooks(sink: Sink, run_id: str) -> dict[str, Any]:
    """Wire scrape.py's hooks to the sink. Returns a counter dict."""
    state: dict[str, Any] = {"snapshot_uri": None, "archived": 0}

    def on_page_html(html: str) -> None:
        try:
            state["snapshot_uri"] = sink.write_text(f"page_snapshots/{run_id}.html", html)
            log.info("page_snapshot_written", uri=state["snapshot_uri"], bytes=len(html))
        except Exception as exc:
            # A failed snapshot must not fail a run that is otherwise fine —
            # but it must be loud, because the snapshot is the whole
            # diagnosis story for the next parsing break.
            log.error("page_snapshot_failed", error=str(exc))

    def on_file_downloaded(local_path: str, url: str) -> None:
        name = Path(local_path).name
        try:
            uri = sink.upload_file(f"source_files/{name}", local_path)
            state["archived"] = int(state["archived"]) + 1
            log.info("source_file_archived", uri=uri, source_url=url)
        except Exception as exc:
            log.error("source_file_archive_failed", file=name, error=str(exc))

    scrape.ON_PAGE_HTML = on_page_html
    scrape.ON_FILE_DOWNLOADED = on_file_downloaded
    return state


def _end_year(value: Any) -> int | None:
    """2026, "2026", or "2025-2026" -> 2026, via the same clean_year() the
    merged output uses, so both sides of the comparison share one convention."""
    cleaned = scrape.clean_year(value)
    match = re.fullmatch(r"20\d{2}-(20\d{2})", str(cleaned))
    return int(match.group(1)) if match else None


def newest_scraped_year(records: list[dict]) -> int | None:
    """The newest school year among the files the scrape found, as an end year."""
    years = [_end_year(r["fiscal_year"]) for r in records if r.get("fiscal_year")]
    return max((y for y in years if y is not None), default=None)


def newest_published_year(page_url: str, delay_seconds: float = 0.0) -> int:
    """The newest School Year in any workbook ``page_url`` links.

    Only a sheet the scraper itself would accept counts (a known race/gender
    column signature), and only its School Year column is read. Raises
    ``ValueError`` when nothing on the page qualifies, which the caller logs
    as the check being unavailable.
    """
    import pandas as pd
    import requests
    from bs4 import BeautifulSoup

    resp = requests.get(page_url, headers=scrape.HEADERS, timeout=60)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, "html.parser")
    workbook_urls = []
    for a_tag in soup.find_all("a", href=True):
        url = urllib.parse.urljoin(page_url, str(a_tag["href"]).strip())
        is_workbook = re.search(r"\.xlsx?$", urllib.parse.urlsplit(url).path, re.IGNORECASE)
        if is_workbook and url not in workbook_urls:
            workbook_urls.append(url)
    if not workbook_urls:
        raise ValueError(f"{page_url} links no workbook")

    newest: int | None = None
    for url in workbook_urls:
        if delay_seconds:
            time.sleep(delay_seconds)
        file_resp = requests.get(url, headers=scrape.HEADERS, timeout=120)
        file_resp.raise_for_status()
        with pd.ExcelFile(io.BytesIO(file_resp.content)) as xls:
            sheet, header = scrape.find_sheet_by_column_signature(xls)
            if sheet is None:
                continue
            columns = pd.read_excel(xls, sheet_name=sheet, header=header, nrows=0).columns
            year_col = next((c for c in columns if scrape.normalize(c) == "schoolyear"), None)
            if year_col is None:
                continue
            values = pd.read_excel(xls, sheet_name=sheet, header=header, usecols=[year_col])
        years = [y for y in (_end_year(v) for v in values[year_col].dropna()) if y is not None]
        if years:
            newest = max(years) if newest is None else max(newest, *years)
    if newest is None:
        raise ValueError(
            f"no workbook linked from {page_url} has a recognizable race/gender "
            "sheet with a School Year column"
        )
    return newest


def _check_for_newer_year(records: list[dict], check_url: str, delay_seconds: float) -> None:
    """Fail when ``check_url`` has a school year the scrape did not collect.

    The check failing to run is a warning, not a failure: a change to a page
    we only watch must not block publishing the one we scrape. The warning has
    its own alert, so a check that has silently stopped working is still seen.
    """
    scraped = newest_scraped_year(records)
    if scraped is None:
        log.warning(
            "newer_year_check_unavailable",
            url=check_url,
            error="no scraped file carries a fiscal year heading to compare against",
        )
        return
    try:
        published = newest_published_year(check_url, delay_seconds)
    except Exception as exc:
        log.warning("newer_year_check_unavailable", url=check_url, error=str(exc))
        return
    log.info("newer_year_checked", url=check_url, scraped=scraped, published=published)
    if published > scraped:
        raise NewerSchoolYearNotScraped(
            f"{check_url} has school year {published - 1}-{published}, but the newest "
            f"year scraped from the enrollment page is {scraped - 1}-{scraped}. "
            "Oklahoma has published a year this pipeline does not collect yet."
        )


def run(
    settings: Settings,
    config: PipelinesConfig,
    *,
    bq: Any | None = None,
    manifest: ManifestWriter | None = None,
    data_dir: Path | None = None,
) -> EnrollmentOutcome:
    """Scrape, reshape, and where a warehouse is configured, publish.

    Raises on zero discovered files or any recorded skip.
    """
    enroll = config.enrollment
    data_dir = data_dir or settings.enrollment_data_dir

    log.info(
        "enrollment_run_started",
        run_id=settings.run_id,
        page_url=enroll.page_url,
        data_dir=str(data_dir),
        target=settings.target,
    )

    _check_robots(enroll.page_url, scrape.HEADERS["User-Agent"])

    scrape.PAGE_URL = enroll.page_url
    scrape.configure(data_dir, delay_seconds=enroll.download_delay_seconds)

    sink = build_sink(settings, PIPELINE)
    hook_state = _install_hooks(sink, settings.run_id)

    manifest = manifest or ManifestWriter(
        bq=bq, local_path=settings.local_output_dir / "pipeline_runs.jsonl"
    )
    record = RunRecord(
        run_id=settings.run_id,
        pipeline=PIPELINE,
        dataset=enroll.table,
        group_name="monthly",
        git_sha=settings.git_sha,
        env=settings.env,
    )

    # Every failure path below must leave a row in owc_ops.pipeline_runs.
    #
    # An earlier version wrapped only scrape.main(), so a failure in the
    # publish stage wrote NO manifest row. That was not academic: a real
    # permission error during publish left marts written and the run failed,
    # Cloud Run retried, the retry short-circuited on the now-warm cache and
    # recorded success_no_change — and the execution reported success with no
    # trace of the failure anywhere the freshness alert could see it.
    # Recorded once, here, for anything that goes wrong.
    recorded = False

    def fail(exc: BaseException) -> None:
        nonlocal recorded
        if recorded:
            return
        recorded = True
        event = getattr(exc, "event", "pipeline_failed")
        log.error(event, error=str(exc), page_url=enroll.page_url, exc_info=True)
        manifest.write(record.finish("failed", error=str(exc)))

    try:
        return _run_inner(
            settings,
            config,
            enroll,
            sink,
            hook_state,
            manifest,
            record,
            bq=bq,
            mark_failed=fail,
        )
    except Exception as exc:
        # NoSourceFilesFound lands here carrying event="no_source_files_found",
        # which is alert #6 — the Oklahoma-redesigned-their-page signal.
        fail(exc)
        raise
    finally:
        scrape.ON_PAGE_HTML = None
        scrape.ON_FILE_DOWNLOADED = None


def _run_inner(
    settings: Settings,
    config: PipelinesConfig,
    enroll: Any,
    sink: Sink,
    hook_state: dict[str, Any],
    manifest: ManifestWriter,
    record: RunRecord,
    *,
    bq: Any | None,
    mark_failed: Any,
) -> EnrollmentOutcome:
    """The run body. Any exception is recorded by the caller's ``fail``."""
    result = scrape.main()

    for warning in result.warnings:
        log.warning(warning["kind"], detail=warning["detail"])

    if result.skips:
        # Each skip gets its own log line so the log-based metrics count
        # files, not runs.
        for skip in result.skips:
            log.error(skip["kind"], detail=skip["detail"])
        message = "; ".join(f"{s['kind']}: {s['detail']}" for s in result.skips)
        error = WorkbookReshapeError(f"{len(result.skips)} file(s) skipped — {message}")
        mark_failed(error)
        raise error

    # Before publishing, and before the short-circuit: a new year that exists
    # only on the other page is exactly the case where the scrape finds
    # nothing new and would otherwise report success.
    if enroll.newer_year_check_url:
        _check_robots(enroll.newer_year_check_url, scrape.HEADERS["User-Agent"])
        _check_for_newer_year(
            result.records, enroll.newer_year_check_url, enroll.download_delay_seconds
        )

    record.source_uri = hook_state["snapshot_uri"] or ""

    if result.short_circuited:
        # The expected outcome most months: Oklahoma has not published a new
        # fiscal year, the cache is intact, and nothing needs republishing.
        log.info(
            "enrollment_short_circuited",
            reason="no new source files",
            archived=hook_state["archived"],
        )
        # Record what is actually published, not 0.
        #
        # A short-circuit means "nothing new to publish", not "the table is
        # empty" — and owc_ops.dataset_freshness surfaces this number to
        # non-technical stakeholders as the answer to "how much data is
        # there?". Writing 0 told them the enrollment table was empty when it
        # held 1.4M rows.
        #
        # get_table().num_rows is metadata, so this is free and instant — no
        # scan. On the very first run the marts table may not exist yet, in
        # which case leave it unset rather than guess.
        record.row_count = None
        if bq is not None:
            try:
                record.row_count = bq.table_row_count(bq.marts, enroll.table)
            except Exception as exc:
                log.warning("marts_row_count_unavailable", table=enroll.table, error=str(exc))
        manifest.write(record.finish("success_no_change"))
        return EnrollmentOutcome(
            rows=0,
            short_circuited=True,
            snapshot_uri=hook_state["snapshot_uri"],
            archived=int(hook_state["archived"]),
            merged_path=result.merged_path,
        )

    record.row_count = result.merged_rows

    if bq is not None and result.merged_path:
        # Write the merged output as Parquet under its own run_id prefix, the
        # same shape lightcast produces. That is what gives enrollment the
        # same rollback artifact — reload this object to undo a bad publish —
        # and it means both pipelines share one publish path. See ADR-010.
        #
        # Read in chunks and stream: the merged CSV is ~1.4M rows, and this
        # keeps peak memory at one Parquet row group rather than the whole
        # frame.
        import pandas as pd
        import pyarrow as pa

        rel_path = f"{enroll.table}/run_id={settings.run_id}/{enroll.table}.parquet"
        header = pd.read_csv(result.merged_path, nrows=0)
        fallback = pa.Schema.from_pandas(header, preserve_index=False)

        with sink.open_write(rel_path) as fh:
            rows, arrow_schema = write_parquet_stream(
                pd.read_csv(result.merged_path, chunksize=200_000),
                fh,
                fallback_schema=fallback,
            )
        parquet_uri = sink.uri(rel_path)
        log.info("merged_parquet_written", uri=parquet_uri, rows=rows)

        from owcdata.core.sinks.bigquery import arrow_to_bq_schema

        previous = manifest.previous_successful(PIPELINE, enroll.table)
        landed = land_parquet(
            bq,
            table=enroll.table,
            source_uris=parquet_uri,
            schema=arrow_to_bq_schema(arrow_schema),
            quality=enroll.quality,
            previous_run=previous,
        )
        record.row_count = landed.row_count
        record.max_year = landed.max_year
        record.bytes = (rows and None) or None
        # source_uri points at the rollback artifact, not the page snapshot:
        # that is what a restore actually needs.
        record.source_uri = parquet_uri

    manifest.write(record.finish("success"))
    log.info(
        "enrollment_run_finished",
        rows=result.merged_rows,
        files=result.reshaped_files,
        archived=hook_state["archived"],
    )
    return EnrollmentOutcome(
        rows=result.merged_rows,
        short_circuited=False,
        snapshot_uri=hook_state["snapshot_uri"],
        archived=int(hook_state["archived"]),
        merged_path=result.merged_path,
    )


__all__ = ["PIPELINE", "EnrollmentOutcome", "run"]
