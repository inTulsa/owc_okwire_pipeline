"""Snowflake connection and streaming Arrow extraction.

Two things here are worth knowing before changing them.

**The credits are not ours.** This is a Lightcast reader account, and reader
account warehouse usage bills to Lightcast, not to us. Concurrency is capped
at 4 tasks in Terraform for that reason, and the queued-statement timeout is
set so a queued query fails instead of holding a paid-for Cloud Run task open.

**Bytes have to transit this process.** ``COPY INTO <location>`` cannot reach
GCS from a reader account — reader accounts cannot ``CREATE STAGE``, and
``COPY INTO`` accepts inline credentials for ``s3://`` and ``azure://`` but
not ``gcs://``, where a storage integration is the only mechanism. So the
result set streams through here. Arrow batches are accumulated to one Parquet
row group at a time, which holds memory at roughly one row group regardless
of whether the dataset is 40 KB or 2.7 GB.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import pyarrow as pa

from owcdata.config import SnowflakeSettings
from owcdata.errors import ExtractError
from owcdata.logging import get_logger

log = get_logger(__name__)


@contextmanager
def connect(settings: SnowflakeSettings) -> Iterator[Any]:
    """An open Snowflake connection, closed on the way out.

    Session parameters are set at connect time rather than with a ``SET``
    statement so they apply even if the query itself fails to start.
    """
    import snowflake.connector

    settings.require_credentials()
    log.info(
        "snowflake_connecting",
        account=settings.account,
        warehouse=settings.warehouse,
        database=settings.database,
        schema=settings.schema_,
        user=settings.user,
    )
    try:
        conn = snowflake.connector.connect(
            account=settings.account,
            user=settings.user,
            password=settings.password,
            warehouse=settings.warehouse,
            database=settings.database,
            schema=settings.schema_,
            session_parameters={
                # Fail fast rather than queue behind other statements while
                # Cloud Run bills for a blocked task.
                "STATEMENT_QUEUED_TIMEOUT_IN_SECONDS": settings.statement_queued_timeout_seconds,
                "STATEMENT_TIMEOUT_IN_SECONDS": settings.statement_timeout_seconds,
            },
            client_session_keep_alive=True,
        )
    except Exception as exc:
        raise ExtractError(f"could not connect to Snowflake: {exc}") from exc

    log.info("snowflake_connected")
    try:
        yield conn
    finally:
        try:
            conn.close()
        except Exception:
            log.warning("snowflake_close_failed")


# Snowflake result type -> Arrow type. Used only for the zero-row case, where
# there is no Arrow batch to take a schema from and an empty Parquet file still
# needs correct columns for the BigQuery load to produce a correct empty table.
def _arrow_type_for(meta: Any) -> pa.DataType:
    import pyarrow as pa
    from snowflake.connector.constants import FIELD_ID_TO_NAME

    name = FIELD_ID_TO_NAME.get(meta.type_code, "TEXT")
    if name == "FIXED":
        scale = meta.scale or 0
        if scale == 0:
            return pa.int64()
        return pa.decimal128(meta.precision or 38, scale)
    return {
        "REAL": pa.float64(),
        "BOOLEAN": pa.bool_(),
        "DATE": pa.date32(),
        "TIME": pa.time64("ns"),
        "TIMESTAMP_NTZ": pa.timestamp("ns"),
        "TIMESTAMP_LTZ": pa.timestamp("ns", tz="UTC"),
        "TIMESTAMP_TZ": pa.timestamp("ns", tz="UTC"),
        "BINARY": pa.binary(),
    }.get(name, pa.string())


@dataclass
class QueryResult:
    """An executed query: its Arrow batches, its id, and its column schema."""

    batches: Iterator[Any]
    query_id: str
    _cursor: Any

    def schema(self) -> pa.Schema:
        """Column schema from the cursor description.

        Only consulted when the result had zero batches — otherwise the schema
        comes off the Arrow batches themselves, which is more faithful.
        """
        import pyarrow as pa

        return pa.schema(
            [
                pa.field(m.name, _arrow_type_for(m), nullable=bool(m.is_nullable))
                for m in self._cursor.description
            ]
        )

    def close(self) -> None:
        try:
            self._cursor.close()
        except Exception:
            log.warning("snowflake_cursor_close_failed")


def arrow_batches(conn: Any, query: str) -> QueryResult:
    """Execute ``query`` and return its Arrow batch iterator plus the query id.

    The Snowflake query id is recorded on the run manifest so a slow or
    expensive extract can be looked up in Snowflake's own history — including
    by Lightcast, if they ever ask what we ran.
    """
    cursor = conn.cursor()
    try:
        cursor.execute(query)
    except Exception as exc:
        cursor.close()
        raise ExtractError(f"query failed: {exc}") from exc

    query_id = getattr(cursor, "sfqid", "") or ""
    log.info("snowflake_query_submitted", query_id=query_id)
    return QueryResult(batches=cursor.fetch_arrow_batches(), query_id=query_id, _cursor=cursor)
