# Architecture

## Data flow

```
                    ┌─────────────────────────────────────────────┐
Cloud Scheduler     │  lightcast: monthly / quarterly / yearly    │
                    │  enrollment: monthly "anything new?"        │
                    └─────────────────────────────────────────────┘
  │  oauth_token, scope cloud-platform   ← NOT oidc_token
  │  retry_count = 0                     ← jobs:run is not idempotent
  ▼
Cloud Run Jobs (one per pipeline, one shared image)
  │
  ├─ lightcast   task_count = one task per dataset in the group
  │              parallelism = 4  ← Snowflake-bound; credits bill to Lightcast
  │              fetch_arrow_batches() → ParquetWriter → streamed GCS upload
  │              task_timeout = 2h
  │
  └─ enrollment  task_count = 1 (inherently sequential)
                 GCS volume mount so data/ and data/data_sources/ persist
                 page HTML snapshotted before parsing
                 task_timeout = 30m
  │
  ▼  both converge on the same path (src/owcdata/core/publish.py)
LOAD      BigQuery batch load (free, atomic) → owc_staging.*
VALIDATE  row counts vs prior run, max(YEAR), not-null, known dim counts
PUBLISH   snapshot marts table → table-copy WRITE_TRUNCATE staging → owc_marts
          → authorized view in owc_reporting
RECORD    one row per dataset per run → owc_ops.pipeline_runs
  │
  ▼  structured JSON logs, non-zero exit on any failure
Cloud Logging → log-based metrics → alert policies → email distribution list
```

Each job performs load / validate / publish **in-process**. See ADR-001.

## The one behavioral change to either pipeline

Both source pipelines swallowed failures and exited 0:

- `owcpipelines/__main__.py:107-114` caught every exception per SQL file,
  printed it, and continued. `:53-55` caught a connection failure and
  returned.
- The enrollment script returned normally on `"No matching files were found on
  the page"`, and per-workbook reshape errors printed `[skip]` and continued.

Cloud Run reads task success from the container exit code. Shipping that
behavior would make every alert in this system permanently green — worse than
having no alerts, because it looks like coverage.

So both pipelines now exit non-zero on failure. That is a wrapper around each
pipeline's main loop, not a change to any query or parsing rule. The exit
codes live in [`src/owcdata/errors.py`](../src/owcdata/errors.py) and are
pinned by [`tests/unit/test_exit_codes.py`](../tests/unit/test_exit_codes.py).

## Accepted risks

Recorded once, deliberately not revisited. Neither pipeline's logic was
rewritten, and these are the consequences.

### 1. Hardcoded year literals in the Lightcast SQL will go stale

`fact_regional_indicators.sql` pins `YEAR = 2025 / 2024 / 2023`; the `*_idx`
files pin a 2015 baseline. On a schedule these produce **wrong-but-plausible**
numbers, which is the worst failure mode there is.

**Mitigation requiring no SQL change:** the quality gate compares each run's
`max(YEAR)` and row count against the previous run and alerts on deviation
(alert 5). A smoke detector, not a fix. Fixing it means editing the SQL, which
was out of scope.

### 2. The seven `*_lagged` datasets are year-shifted copies

`fact_emp_lagged`, `fact_has_lagged`, `fact_jobs_lagged`,
`fact_skills_lagged`, `fact_completions_lagged`, `fact_enrollments_lagged`,
`fact_emp_lagged_2` roughly double extract cost for two of the three largest
tables. Left as-is. Nothing here blocks revisiting it — they are ordinary
datasets in `pipelines.yml`.

### 3. The enrollment scraper's selectors are pinned to Oklahoma's current markup

Unchangeable by us. Mitigated by snapshotting the page HTML every run to
`gs://<raw>/enrollment/page_snapshots/<run_id>.html`, so a break is
diagnosable by diff in minutes rather than by re-reading 759 lines. Also
mitigated by the fixture tests in
[`tests/unit/test_enrollment_parsing.py`](../tests/unit/test_enrollment_parsing.py),
which pin current behavior against saved HTML and workbooks.

---

# Decision records

## ADR-001: Load / validate / publish in-process, not Cloud Workflows

**Status:** accepted.

Cloud Workflows would add durable step-level retries and a Cloud Run connector
that blocks until completion. It would also add another component for a small
team to learn, debug, and keep in Terraform.

**Decision:** each job does load, validate, and publish in-process. The
retry-worthy part — the extract — is already covered by Cloud Run's
`max_retries`, and the publish stage is two free, atomic BigQuery jobs that
either work or fail loudly.

**Revisit if** publish-stage retries ever need to be independent of the
extract, e.g. if publishing grows a step that can fail transiently on its own.

## ADR-002: Marts tables are unpartitioned and unclustered

**Status:** accepted.

Partitioning on `YEAR` with `YEAR >= 2015` gives ~11 partitions of ~100–150 MB
— well below the ~1 GB threshold where partitioning pays for itself. That buys
metadata overhead for pruning nobody needs.

Clustering prunes on a **left prefix** only, so column order is load-bearing
and has to match what PowerBI actually filters on. That is unknowable until
the PowerBI mode is settled (open item 5), and guessing at four columns now
would likely be wrong.

**Decision:** ship unpartitioned and unclustered. Measure. Partition only if a
table passes ~10 GB, and cluster only once the real filter columns are known.

`owc_ops.pipeline_runs` *is* partitioned and clustered, because that table is
genuinely queried by time on every freshness check.

## ADR-003: Publish with a table-copy job, not CREATE OR REPLACE TABLE AS SELECT

**Status:** accepted.

Both are atomic. The copy job is **free** — no slots, no bytes billed — and
**preserves the source schema and clustering**. `CREATE OR REPLACE TABLE AS
SELECT` bills a full scan of staging on every run and silently drops
clustering if the DDL omits it.

BigQuery load jobs are already atomic: creation, truncation, and append occur
as one atomic update on job completion. So the staging load needs no wrapper.

A **table snapshot is taken before each swap**. Near-free — it bills only for
bytes that later diverge — and it makes a rollback one copy job:
`owcdata rollback <table> <snapshot>`.

## ADR-004: Snowflake password auth is kept

**Status:** accepted, with a verification outstanding.

Snowflake's password deprecation explicitly exempts reader accounts: the
phases described "don't apply to reader accounts… you can continue to sign in
to these types of accounts with a single-factor password."

**Decision:** no auth migration. The password moves to Secret Manager; that is
the only change, which matches "works the same way it currently does."

**Outstanding (open item 3):** confirm `EMSIBG-READER_TULSA_FOR_YOU` is a true
reader account and not a regular account holding a share. Run
`SELECT CURRENT_ACCOUNT()`, or ask Lightcast. If it is the latter the exemption
lapses and key-pair auth becomes time-sensitive.

## ADR-005: Snowflake COPY INTO to GCS is unavailable — bytes transit Cloud Run

**Status:** accepted (forced).

Not permission-gated; structurally unavailable, for two independent reasons:

1. Reader accounts cannot `CREATE STAGE`.
2. `COPY INTO <location>` accepts inline `CREDENTIALS` for `s3://` and
   `azure://` but **not** for `gcs://`, where a storage integration is the only
   mechanism.

**Consequence, which is fine:** the result set streams through the container.
Arrow batches are accumulated to one Parquet row group at a time, so peak
memory tracks the row-group target rather than the result size. Measured: a
1.6 GB and a 3.2 GB result set peak identically, at ~290 MB with a 64 MiB row
group. Tasks need 2 GiB, not 32. This also removed the CSV intermediate and
the `polars` dependency the original pipeline carried.

## ADR-006: One tightly-scoped JSON key for PowerBI

**Status:** accepted, as a documented exception.

The PowerBI BigQuery connector authenticates as a Google organizational
account or via a **service-account JSON key** — exactly what a no-keys policy
exists to prevent. There is no third option.

The alternative, per-user OAuth, breaks scheduled refresh the day that person
leaves.

**Decision:** one key for `okw-powerbi-{env}`, scoped to `bigquery.dataViewer`
on `owc_reporting` **only** plus `bigquery.jobUser`. No grant on `owc_marts` —
the authorized views read marts on their own authority. Rotate annually.

Decided and written down here rather than discovered at go-live.

## ADR-007: One container image for both pipelines

**Status:** accepted.

Separate images per pipeline would be tidier but double the build and deploy
configuration. Image size is irrelevant at this scale, and one image is far
easier for a small team to reason about. `owcdata run <pipeline>` selects.

## ADR-008: The enrollment script is a generated derivation, not a hand-edited copy

**Status:** accepted.

The design commits to carrying the enrollment script over with its parsing,
reshaping, and caching logic unchanged. A commitment like that decays the
moment someone runs a formatter over the file — which happened once during
this build and turned a 9-line change set into a 43-line one.

**Decision:** [`scrape.py`](../src/owcdata/pipelines/enrollment/scrape.py) is
**generated** by
[`scripts/derive_scrape.py`](../scripts/derive_scrape.py) from the pristine
original at
[`tests/fixtures/primary_enrollment_data_script.original.py`](../tests/fixtures/primary_enrollment_data_script.original.py),
via an explicit ordered list of substitutions that must each match exactly
once. It is excluded from `ruff format`, and CI runs
`derive_scrape.py --check`.

The result: `make diff-enrollment` shows exactly 9 removed lines, forever, and
any drift is a build failure rather than a slow erosion of the claim.
