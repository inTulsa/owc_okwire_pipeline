"""Pipeline failure taxonomy.

Every one of these exits the process non-zero. That is the whole point: Cloud
Run reads task success from the container exit code, and both source pipelines
swallowed their failures and exited 0. An alert on a pipeline that always
reports success is permanently green and therefore worthless.

Each subclass carries an ``event`` string that lands in the structured log as
``jsonPayload.event``. The log-based metrics in
``infra/terraform/modules/pipeline`` match on those exact strings, so renaming
one here without renaming it there silently disables an alert.
"""

from __future__ import annotations


class PipelineError(Exception):
    """Base class for every failure that must exit non-zero."""

    event = "pipeline_failed"
    exit_code = 1


class ConfigError(PipelineError):
    """Bad or missing configuration. Raised before any network call."""

    event = "config_invalid"
    exit_code = 2


class ExtractError(PipelineError):
    """A source query or download failed."""

    event = "extract_failed"
    exit_code = 3


class NoSourceFilesFound(ExtractError):
    """The scrape found zero matching files on the page.

    This is the single most likely failure this pipeline will ever have, and
    it is exactly what Oklahoma redesigning their webpage looks like. The
    original script printed "Nothing to do." and returned normally.
    """

    event = "no_source_files_found"
    exit_code = 4


class WorkbookReshapeError(PipelineError):
    """One or more workbooks were skipped during reshape.

    The original script printed ``[skip]`` and continued, so a fiscal year
    could quietly vanish from the merged CSV with no trace outside stdout.
    """

    event = "workbook_reshape_skipped"
    exit_code = 5


class LoadError(PipelineError):
    """A BigQuery load job failed."""

    event = "load_failed"
    exit_code = 6


class QualityCheckError(PipelineError):
    """A quality check failed, blocking publish.

    Staging is deliberately left in place so the failing data can be queried
    and diffed against the previous run.
    """

    event = "quality_check_failed"
    exit_code = 7


class PublishError(PipelineError):
    """A snapshot or table-copy job failed."""

    event = "publish_failed"
    exit_code = 8
