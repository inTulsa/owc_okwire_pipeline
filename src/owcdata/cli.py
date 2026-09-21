"""``owcdata`` — one entry point, both pipelines, one container image.

Separate images per pipeline would be tidier but double the build and deploy
configuration for no benefit: image size is irrelevant here and one image is
far easier for a small team to reason about. ``owcdata run <pipeline>``
selects which one.

**Exit codes are the product.** Cloud Run reads task success from the exit
code, and every alert in ``infra/terraform/modules/pipeline`` depends on this
process exiting non-zero when something went wrong. The codes come from
``owcdata.errors``.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Annotated

import typer

from owcdata import logging as owclog
from owcdata.config import PipelinesConfig, Settings, get_pipelines_config, get_settings
from owcdata.core.manifest import new_run_id
from owcdata.errors import ConfigError, PipelineError

app = typer.Typer(
    add_completion=False,
    no_args_is_help=True,
    help="OWC data platform: the lightcast and enrollment pipelines.",
)


def _git_sha() -> str:
    """The deployed commit. Cloud Run gets it as an env var; a laptop asks git."""
    if sha := os.getenv("OWC_GIT_SHA"):
        return sha
    try:
        return subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        ).stdout.strip()
    except Exception:
        return "unknown"


def _resolve_run_id(settings: Settings) -> str:
    """A run id shared by every task in one Cloud Run execution.

    Cloud Run sets CLOUD_RUN_EXECUTION to the execution name, which is the
    same across tasks — so all 41 tasks land under one run_id and the manifest
    can be grouped by run. A per-task id would make that impossible.
    """
    if settings.run_id:
        return settings.run_id
    if execution := os.getenv("CLOUD_RUN_EXECUTION"):
        return execution
    return new_run_id()


def _build_settings(target: str | None, env: str | None, pipelines_file: Path | None) -> Settings:
    # Env vars are the transport into pydantic-settings, so a CLI flag wins by
    # setting the var the same way Cloud Run would.
    if target:
        os.environ["OWC_TARGET"] = target
    if env:
        os.environ["OWC_ENV"] = env
    if pipelines_file:
        os.environ["OWC_PIPELINES_FILE"] = str(pipelines_file)
    get_settings.cache_clear()
    get_pipelines_config.cache_clear()
    settings = get_settings()
    settings.run_id = _resolve_run_id(settings)
    settings.git_sha = _git_sha()
    return settings


def _build_bq(settings: Settings):
    """A BigQuery client, or None when running locally.

    ``--target local`` skips the warehouse entirely and reproduces the
    original pipelines' on-disk behavior, which is what makes a laptop run
    useful without GCP credentials.
    """
    if settings.target != "gcs":
        return None
    from owcdata.core.sinks.bigquery import BigQueryClient

    return BigQueryClient(
        settings.gcp_project,
        location=settings.bq_location,
        staging_dataset=settings.bq_staging_dataset,
        marts_dataset=settings.bq_marts_dataset,
        ops_dataset=settings.bq_ops_dataset,
    )


@app.command()
def run(
    pipeline: Annotated[str, typer.Argument(help="lightcast | enrollment")],
    dataset: Annotated[
        str | None, typer.Option(help="One lightcast dataset, e.g. dim_area")
    ] = None,
    group: Annotated[
        str | None, typer.Option(help="One lightcast schedule group: monthly|quarterly|yearly")
    ] = None,
    limit: Annotated[
        int | None,
        typer.Option(
            help="Row-limit every query. Wraps the SQL in memory; files on disk are never modified."
        ),
    ] = None,
    target: Annotated[str | None, typer.Option(help="local | gcs")] = None,
    env: Annotated[str | None, typer.Option(help="dev | prod")] = None,
    pipelines_file: Annotated[Path | None, typer.Option(help="Override pipelines.yml")] = None,
) -> None:
    """Run a pipeline. Exits non-zero on any failure."""
    settings = _build_settings(target, env, pipelines_file)
    owclog.configure(level=settings.log_level)
    owclog.bind_run(run_id=settings.run_id, pipeline=pipeline, env=settings.env)
    log = owclog.get_logger("owcdata.cli")

    try:
        config = get_pipelines_config()
        bq = _build_bq(settings)

        if pipeline == "lightcast":
            from owcdata.pipelines.lightcast import run as lightcast

            lightcast.run(settings, config, group=group, dataset=dataset, limit=limit, bq=bq)
        elif pipeline == "enrollment":
            if dataset or group or limit:
                raise ConfigError(
                    "--dataset/--group/--limit apply to lightcast only; "
                    "enrollment has one dataset and its volume is set by the source"
                )
            from owcdata.pipelines.enrollment import run as enrollment

            enrollment.run(settings, config, bq=bq)
        else:
            raise ConfigError(f"unknown pipeline {pipeline!r}; expected lightcast or enrollment")

    except PipelineError as exc:
        log.error(exc.event, error=str(exc), exit_code=exc.exit_code)
        raise typer.Exit(exc.exit_code) from exc
    except Exception as exc:
        # Anything unanticipated still has to be a non-zero exit. A crash that
        # exits 0 is the failure mode this whole project exists to remove.
        log.error("pipeline_failed", error=str(exc), exc_info=True)
        raise typer.Exit(1) from exc

    log.info("pipeline_succeeded")


@app.command()
def validate(
    pipelines_file: Annotated[Path | None, typer.Option()] = None,
) -> None:
    """Check config and parse every SQL file. No network, no credentials."""
    owclog.configure(json_logs=False)
    log = owclog.get_logger("owcdata.validate")
    problems: list[str] = []

    try:
        config = PipelinesConfig.load(pipelines_file) if pipelines_file else get_pipelines_config()
    except ConfigError as exc:
        typer.echo(f"FAIL  pipelines.yml: {exc}", err=True)
        raise typer.Exit(2) from exc
    typer.echo("OK    pipelines.yml parses and validates")

    from owcdata.pipelines.lightcast.datasets import is_single_statement, prepare_query, resolve

    datasets = resolve(config.lightcast)
    typer.echo(f"OK    {len(datasets)} SQL file(s) found in {config.lightcast.source_dir}")

    for ds in datasets:
        sql = ds.read_sql()
        if not sql.strip():
            problems.append(f"{ds.name}.sql is empty")
            continue
        # The --limit path is the one that rewrites text, so it is the one
        # worth checking: an unwrappable query would become a syntax error
        # only at runtime, against a billed warehouse.
        if not is_single_statement(sql):
            problems.append(f"{ds.name}.sql has more than one statement, so --limit cannot wrap it")
            continue
        try:
            prepare_query(sql, limit=1)
        except ConfigError as exc:
            problems.append(f"{ds.name}.sql: {exc}")

    by_group: dict[str, int] = {}
    for ds in datasets:
        by_group[ds.group] = by_group.get(ds.group, 0) + 1
    for group_name, group in config.lightcast.groups.items():
        typer.echo(
            f"OK    group {group_name:<10} {by_group.get(group_name, 0):>3} dataset(s)  "
            f"schedule={group.schedule!r}"
        )

    typer.echo(
        f"OK    enrollment table={config.enrollment.table} schedule={config.enrollment.schedule!r}"
    )

    # The enrollment cache dir must never be the repo's own "data" path or a
    # local run could clobber a FUSE-mounted production cache.
    settings = get_settings()
    if (
        settings.target == "local"
        and Path(settings.enrollment_data_dir).resolve() == Path("data").resolve()
    ):
        problems.append(
            "OWC_ENROLLMENT_DATA_DIR resolves to ./data for a local run; "
            "use a separate directory so a local test cannot corrupt the production cache"
        )

    if problems:
        for p in problems:
            typer.echo(f"FAIL  {p}", err=True)
        raise typer.Exit(2)
    typer.echo(f"\nAll checks passed ({len(datasets)} datasets, 2 pipelines).")
    log.info("validate_passed", datasets=len(datasets))


@app.command()
def datasets(
    group: Annotated[str | None, typer.Option(help="Filter to one group")] = None,
) -> None:
    """List lightcast datasets and their schedule group."""
    config = get_pipelines_config()
    from owcdata.pipelines.lightcast.datasets import resolve

    for ds in resolve(config.lightcast, group=group):
        typer.echo(f"{ds.group:<10} {ds.name}")


@app.command(name="rollback")
def rollback_cmd(
    table: Annotated[str, typer.Argument(help="Marts table to roll back")],
    run_id: Annotated[
        str | None,
        typer.Option(
            help="Restore the Parquet this run produced. Looked up in owc_ops.pipeline_runs."
        ),
    ] = None,
    source_uri: Annotated[
        str | None, typer.Option(help="Restore this gs:// Parquet object directly.")
    ] = None,
) -> None:
    """Roll a marts table back to a previous run's output.

    The rollback artifact is the Parquet that run wrote to GCS, retained under
    its own run_id prefix. With neither option, the last successful run before
    the current contents is used.
    """
    settings = _build_settings("gcs", None, None)
    owclog.configure(level=settings.log_level)
    log = owclog.get_logger("owcdata.rollback")
    bq = _build_bq(settings)
    assert bq is not None

    if source_uri is None:
        sql = f"""
            SELECT run_id, source_uri, row_count, finished_at
            FROM `{bq.project}.{bq.ops}.pipeline_runs`
            WHERE dataset = @table
              AND status = 'success'
              AND source_uri LIKE 'gs://%'
              {"AND run_id = @run_id" if run_id else ""}
            ORDER BY finished_at DESC
            LIMIT {1 if run_id else 2}
        """
        params = {"table": table}
        if run_id:
            params["run_id"] = run_id
        rows = bq.query_rows(sql, params)
        if not rows:
            typer.echo(f"no successful run with a GCS artifact found for {table}", err=True)
            raise typer.Exit(2)
        # Without an explicit run_id, "previous" means the one before current.
        chosen = rows[0] if run_id or len(rows) == 1 else rows[1]
        source_uri = chosen["source_uri"]
        typer.echo(f"restoring from run {chosen['run_id']} ({chosen['row_count']} rows)")

    restored = bq.restore_from_uri(table=table, source_uri=source_uri)
    typer.echo(f"{table} restored to {restored} rows from {source_uri}")
    log.info("rollback_complete", table=table, source_uri=source_uri, rows=restored)


def main() -> None:
    app()


if __name__ == "__main__":
    sys.exit(app())
