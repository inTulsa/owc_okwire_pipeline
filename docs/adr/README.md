# Decision records

The ADRs live inline in [`../01-architecture.md`](../01-architecture.md) rather
than as separate files — there are eight of them and they are short enough that
splitting them across eight files costs more in navigation than it buys in
tidiness.

| # | Decision |
|---|---|
| 001 | Load/validate/publish in-process, not Cloud Workflows |
| 002 | Marts tables unpartitioned and unclustered |
| 003 | Publish with a table-copy job, not CREATE OR REPLACE |
| 004 | Snowflake password auth is kept (reader-account exemption) |
| 005 | COPY INTO to GCS is unavailable — bytes transit Cloud Run |
| 006 | One tightly-scoped JSON key for PowerBI |
| 007 | One container image for both pipelines |
| 008 | The enrollment script is a generated derivation |
| 009 | No reporting layer — the pipeline stops at `owc_marts` (supersedes the three-dataset split) |
| 010 | Rollback from the GCS Parquet, not a BigQuery snapshot (supersedes ADR-003's snapshot step); no custom IAM roles |

Add a ninth by appending to `01-architecture.md` and adding a row here.
