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
"""

from __future__ import annotations

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
from owcdata.errors import ExtractError, WorkbookReshapeError
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
