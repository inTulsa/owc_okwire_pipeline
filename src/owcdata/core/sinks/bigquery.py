"""BigQuery: batch loads, snapshots, table copies, authorized views.

Three deliberate choices, each overturning a more obvious alternative:

**Loads need no atomicity wrapper.** A BigQuery load job's "creation,
truncation and append occur as one atomic update upon job completion", so a
failed load leaves the previous table contents untouched. Batch loads are also
free.

**Publish is a table-copy job, not ``CREATE OR REPLACE TABLE AS SELECT``.**
Both are atomic, but a copy job bills nothing — no slots, no bytes — and
preserves the source schema and clustering. CREATE-OR-REPLACE bills a full
scan of staging on every run and silently drops clustering if the DDL omits
it.

**Schemas are passed explicitly, derived from the Arrow schema at runtime.**
Autodetect on a multi-file Parquet load infers from the alphabetically last
file, which is a real hazard the moment a dataset spans more than one object.
"""

from __future__ import annotations

from typing import Any

import pyarrow as pa

from owcdata.errors import LoadError, PublishError
from owcdata.logging import get_logger

log = get_logger(__name__)

# Arrow -> BigQuery. Anything unmapped falls through to STRING, which loses
# no data and shows up plainly in the published table rather than failing a
# load at 3am.
_ARROW_TO_BQ: list[tuple[Any, str]] = [
    (pa.types.is_boolean, "BOOL"),
    (pa.types.is_integer, "INT64"),
    (pa.types.is_floating, "FLOAT64"),
    (pa.types.is_decimal, "NUMERIC"),
    (pa.types.is_date, "DATE"),
    (pa.types.is_time, "TIME"),
    (pa.types.is_timestamp, "TIMESTAMP"),
    (pa.types.is_binary, "BYTES"),
    (pa.types.is_large_binary, "BYTES"),
    (pa.types.is_string, "STRING"),
    (pa.types.is_large_string, "STRING"),
]


def bq_type_for(arrow_type: pa.DataType) -> str:
    for predicate, bq_type in _ARROW_TO_BQ:
        if predicate(arrow_type):
            return bq_type
    return "STRING"


def arrow_to_bq_schema(schema: pa.Schema) -> list[Any]:
    """Explicit BigQuery schema for an Arrow schema.

    Every field is NULLABLE. Snowflake nullability does not survive the Arrow
    result faithfully enough to assert REQUIRED, and a wrong REQUIRED fails
    the load rather than the quality gate — the not-null checks in
    ``core/quality.py`` are the right place for that assertion.
    """
    from google.cloud import bigquery

    return [
        bigquery.SchemaField(field.name, bq_type_for(field.type), mode="NULLABLE")
        for field in schema
    ]


def pandas_to_bq_schema(df: Any) -> list[Any]:
    """Explicit BigQuery schema for a pandas DataFrame (the enrollment path)."""
    return arrow_to_bq_schema(pa.Schema.from_pandas(df, preserve_index=False))


class BigQueryClient:
    """Thin wrapper holding the project, location, and dataset names."""

    def __init__(
        self,
        project: str,
        *,
        location: str = "US",
        staging_dataset: str = "owc_staging",
        marts_dataset: str = "owc_marts",
        reporting_dataset: str = "owc_reporting",
        ops_dataset: str = "owc_ops",
        client: Any | None = None,
    ) -> None:
        from google.cloud import bigquery

        self.project = project
        self.location = location
        self.staging = staging_dataset
        self.marts = marts_dataset
        self.reporting = reporting_dataset
        self.ops = ops_dataset
        self._bq = bigquery
        self.client = client or bigquery.Client(project=project, location=location)

    # -- helpers ----------------------------------------------------------
    def ref(self, dataset: str, table: str) -> str:
        return f"{self.project}.{dataset}.{table}"

    def _wait(self, job: Any, what: str, error: type[Exception]) -> Any:
        try:
            return job.result()
        except Exception as exc:
            errors = getattr(job, "errors", None)
            raise error(f"{what} failed: {exc}{f' | {errors}' if errors else ''}") from exc

    # -- load -------------------------------------------------------------
    def load_parquet(
        self,
        *,
        table: str,
        source_uris: str | list[str],
        schema: list[Any] | None = None,
    ) -> int:
        """Load Parquet from GCS into ``staging.table``, replacing it.

        Returns the row count of the loaded table.
        """
        uris = [source_uris] if isinstance(source_uris, str) else list(source_uris)
        target = self.ref(self.staging, table)
        job_config = self._bq.LoadJobConfig(
            source_format=self._bq.SourceFormat.PARQUET,
            write_disposition=self._bq.WriteDisposition.WRITE_TRUNCATE,
        )
        if schema:
            job_config.schema = schema
        else:
            job_config.autodetect = True

        log.info("bq_load_started", table=target, uris=uris)
        job = self.client.load_table_from_uri(
            uris, target, job_config=job_config, location=self.location
        )
        self._wait(job, f"load into {target}", LoadError)
        rows = int(self.client.get_table(target).num_rows)
        log.info("bq_load_finished", table=target, rows=rows, bytes=job.output_bytes or 0)
        return rows

    def load_dataframe(self, *, table: str, df: Any, schema: list[Any] | None = None) -> int:
        """Load a pandas DataFrame into ``staging.table`` (the enrollment path).

        The enrollment output is a single small CSV, so there is nothing to
        gain from staging it through GCS first.
        """
        target = self.ref(self.staging, table)
        job_config = self._bq.LoadJobConfig(
            write_disposition=self._bq.WriteDisposition.WRITE_TRUNCATE,
            schema=schema or pandas_to_bq_schema(df),
        )
        log.info("bq_load_started", table=target, rows=len(df))
        job = self.client.load_table_from_dataframe(
            df, target, job_config=job_config, location=self.location
        )
        self._wait(job, f"load into {target}", LoadError)
        rows = int(self.client.get_table(target).num_rows)
        log.info("bq_load_finished", table=target, rows=rows)
        return rows

    # -- query ------------------------------------------------------------
    def query_rows(self, sql: str, params: dict[str, Any] | None = None) -> list[dict]:
        job_config = None
        if params:
            job_config = self._bq.QueryJobConfig(
                query_parameters=[_query_param(k, v) for k, v in params.items()]
            )
        job = self.client.query(sql, job_config=job_config, location=self.location)
        return [dict(row) for row in job.result()]

    def insert_rows(self, dataset: str, table: str, rows: list[dict]) -> None:
        table_ref = self.client.get_table(self.ref(dataset, table))
        errors = self.client.insert_rows_json(table_ref, rows)
        if errors:
            raise LoadError(f"streaming insert into {dataset}.{table} failed: {errors}")

    def table_exists(self, dataset: str, table: str) -> bool:
        from google.api_core import exceptions

        try:
            self.client.get_table(self.ref(dataset, table))
            return True
        except exceptions.NotFound:
            return False

    def table_row_count(self, dataset: str, table: str) -> int:
        return int(self.client.get_table(self.ref(dataset, table)).num_rows)

    # -- publish ----------------------------------------------------------
    def snapshot(self, *, table: str, run_id: str, expiration_days: int = 30) -> str | None:
        """Snapshot ``marts.table`` before it is replaced.

        Near-free: a snapshot bills only for bytes that later diverge from the
        base table. Makes a rollback one copy job instead of a re-run.
        """
        if not self.table_exists(self.marts, table):
            log.info("bq_snapshot_skipped", table=table, reason="marts table does not exist yet")
            return None

        import datetime as _dt

        name = f"{table}__{run_id}"
        target = self.ref(self.ops, name)
        job_config = self._bq.CopyJobConfig(
            operation_type=self._bq.OperationType.SNAPSHOT,
            write_disposition=self._bq.WriteDisposition.WRITE_EMPTY,
        )
        # Serialized as RFC 3339 on the wire, so pass a string.
        job_config.destination_expiration_time = (
            _dt.datetime.now(_dt.UTC) + _dt.timedelta(days=expiration_days)
        ).isoformat()
        job = self.client.copy_table(
            self.ref(self.marts, table), target, job_config=job_config, location=self.location
        )
        self._wait(job, f"snapshot {table}", PublishError)
        log.info("bq_snapshot_created", snapshot=target)
        return target

    def copy_to_marts(self, table: str) -> None:
        """Replace ``marts.table`` with ``staging.table`` atomically and free."""
        source, target = self.ref(self.staging, table), self.ref(self.marts, table)
        job_config = self._bq.CopyJobConfig(
            write_disposition=self._bq.WriteDisposition.WRITE_TRUNCATE
        )
        job = self.client.copy_table(source, target, job_config=job_config, location=self.location)
        self._wait(job, f"copy {source} -> {target}", PublishError)
        log.info("bq_published", table=target)

    def restore_from_snapshot(self, *, table: str, snapshot: str) -> None:
        """Roll ``marts.table`` back to a snapshot taken by ``snapshot()``."""
        job_config = self._bq.CopyJobConfig(
            write_disposition=self._bq.WriteDisposition.WRITE_TRUNCATE
        )
        job = self.client.copy_table(
            snapshot, self.ref(self.marts, table), job_config=job_config, location=self.location
        )
        self._wait(job, f"restore {table} from {snapshot}", PublishError)
        log.info("bq_restored", table=table, snapshot=snapshot)

    def ensure_authorized_view(self, table: str) -> None:
        """A pass-through view in ``reporting`` authorized to read ``marts``.

        This is the step most often forgotten, and the entire reason for the
        three-dataset split: an authorized view reads ``owc_marts`` on its own
        authority, so the PowerBI service account needs — and gets — no grant
        on ``owc_marts`` at all.
        """
        view_id = self.ref(self.reporting, table)
        view = self._bq.Table(view_id)
        view.view_query = f"SELECT * FROM `{self.ref(self.marts, table)}`"

        from google.api_core import exceptions

        try:
            self.client.create_table(view)
            log.info("bq_view_created", view=view_id)
        except exceptions.Conflict:
            self.client.update_table(view, ["view_query"])
            log.info("bq_view_updated", view=view_id)

        # Authorize it on the marts dataset. Read-modify-write of the access
        # list, so an unrelated grant added by hand is not clobbered.
        marts = self.client.get_dataset(f"{self.project}.{self.marts}")
        entries = list(marts.access_entries)
        already = any(
            getattr(e.entity_id, "get", lambda _k: None)("tableId") == table
            for e in entries
            if e.entity_type == "view" and isinstance(e.entity_id, dict)
        )
        if already:
            return
        entries.append(
            self._bq.AccessEntry(
                role=None,
                entity_type="view",
                entity_id={
                    "projectId": self.project,
                    "datasetId": self.reporting,
                    "tableId": table,
                },
            )
        )
        marts.access_entries = entries
        self.client.update_dataset(marts, ["access_entries"])
        log.info("bq_view_authorized", view=view_id, dataset=self.marts)


def _query_param(name: str, value: Any) -> Any:
    from google.cloud import bigquery

    kind = {bool: "BOOL", int: "INT64", float: "FLOAT64"}.get(type(value), "STRING")
    return bigquery.ScalarQueryParameter(name, kind, value)
