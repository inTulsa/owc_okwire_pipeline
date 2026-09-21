# Runbook

One entry per alert: symptom → diagnosis → fix. Start with the alert you got.

**Set these once per shell:**

```bash
export ENV=dev                      # or prod
export PROJECT=owc-data-$ENV
export REGION=us-central1
```

## Exit codes

Every failure exits non-zero, and the code names the cause. From
[`src/owcdata/errors.py`](../src/owcdata/errors.py):

| Code | Meaning | Where to look |
|---|---|---|
| 1 | Unanticipated crash | The traceback in the log |
| 2 | `config_invalid` | `pipelines.yml` or a missing env var |
| 3 | `extract_failed` | Snowflake, or a download |
| 4 | `no_source_files_found` | [Alert 6](#alert-6-no-files) — the Oklahoma page changed |
| 5 | `workbook_reshape_skipped` | [Alert 7](#alert-7-reshape-skipped) |
| 6 | `load_failed` | BigQuery load job errors |
| 7 | `quality_check_failed` | [Alert 4](#alert-4-quality) — publish was blocked |
| 8 | `publish_failed` | Snapshot, copy, or view wiring |

## First moves for any alert

```bash
# What ran, what it did, and whether it failed
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT run_id, pipeline, dataset, status, row_count, max_year,
        finished_at, LEFT(error, 200) AS error
 FROM `owc_ops.pipeline_runs`
 WHERE started_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
 ORDER BY started_at DESC LIMIT 40'
```

```bash
# The structured logs for one run
gcloud logging read \
  'resource.type="cloud_run_job" jsonPayload.run_id="RUN_ID"' \
  --project=$PROJECT --limit=200 --format='value(jsonPayload.event,jsonPayload.dataset,jsonPayload.error)'
```

---

## ALERT 1: task failed {#alert-1-task-failed}

**Symptom.** A Cloud Run task exited non-zero after exhausting its 3 retries.

**Diagnose.** Find the failing dataset and its exit code:

```bash
gcloud logging read \
  'resource.type="cloud_run_job" severity>=ERROR' \
  --project=$PROJECT --limit=50 \
  --format='table(timestamp,jsonPayload.dataset,jsonPayload.event,jsonPayload.error)'
```

**Fix.** Re-run just that dataset — one dataset per task means the retry is
surgical and does not re-bill Lightcast for the 40 that already succeeded:

```bash
gcloud run jobs execute okw-lightcast-$ENV --region=$REGION --project=$PROJECT \
  --args="run,lightcast,--dataset,THE_DATASET" --wait
```

**If it is a Snowflake error**, get the query id off the manifest and look it
up in Snowflake's own history — that tells you whether it was a timeout, a
queue eviction, or a real SQL problem:

```bash
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT dataset, source_query_id, error FROM `owc_ops.pipeline_runs`
 WHERE status = "failed" ORDER BY started_at DESC LIMIT 10'
```

**If several tasks failed at once**, suspect the warehouse rather than the
queries: `TULSA_FOR_YOU_WH` may be suspended by a Lightcast-side resource
monitor, or queued statements are hitting
`STATEMENT_QUEUED_TIMEOUT_IN_SECONDS`. Lower `parallelism` and talk to
Lightcast — it is their warehouse and their credits.

---

## ALERT 2: didn't run {#alert-2-didnt-run}

**Symptom.** A schedule group has had no successful run inside its interval
plus grace.

**This is the only alert that catches a scheduler that quietly stopped.** A
green Cloud Scheduler history proves nothing: `jobs:run` returns a
long-running Operation immediately, so Scheduler gets a 200 in milliseconds
regardless of what the job then does.

**Diagnose.**

```bash
# What is overdue
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT * FROM `owc_ops.dataset_freshness` ORDER BY hours_since_success DESC LIMIT 20'

# Is the scheduler even enabled?
gcloud scheduler jobs list --location=$REGION --project=$PROJECT
gcloud scheduler jobs describe okw-lightcast-monthly-$ENV --location=$REGION --project=$PROJECT
```

**Fix, by cause:**

| Cause | Fix |
|---|---|
| Scheduler is PAUSED | `gcloud scheduler jobs resume okw-lightcast-monthly-$ENV --location=$REGION` |
| Scheduler was deleted | `make tf-apply ENV=$ENV` |
| Scheduler fires but jobs never start | That is [alert 3](#alert-3-scheduler-failing) |
| Jobs run but the manifest is empty | Check for `manifest_write_failed` in the logs — the run may be fine while the record-keeping is broken, which disables this alert. Verify `bigquery.dataEditor` on `owc_ops`. |

Then catch up manually:

```bash
gcloud run jobs execute okw-lightcast-$ENV --region=$REGION --project=$PROJECT \
  --args="run,lightcast,--group,monthly" --tasks=41 --wait
```

---

## ALERT 3: scheduler failing {#alert-3-scheduler-failing}

**Symptom.** Cloud Scheduler logged an error invoking a job. Nothing started,
so no Cloud Run metric exists and alert 1 cannot fire.

**Diagnose.**

```bash
gcloud logging read \
  'resource.type="cloud_scheduler_job" severity>=ERROR' \
  --project=$PROJECT --limit=20 --format='value(timestamp,jsonPayload.status,textPayload)'
```

**Fix.** Almost always one of two things:

1. **401 / UNAUTHENTICATED** — the token type. Calling `run.googleapis.com`
   requires an **`oauth_token`** with scope `cloud-platform`. An `oidc_token`
   gives exactly this error and is the classic misconfiguration for this
   pattern. Terraform sets `oauth_token`; confirm nothing has been changed by
   hand:

   ```bash
   gcloud scheduler jobs describe okw-lightcast-monthly-$ENV \
     --location=$REGION --project=$PROJECT --format='yaml(httpTarget)'
   ```

2. **403 / PERMISSION_DENIED** — the scheduler service account lost
   `roles/run.invoker` on the job. `make tf-apply ENV=$ENV` restores it.

---

## ALERT 4: quality check failed — publish blocked {#alert-4-quality}

**Symptom.** New data failed a check, so the publish was blocked. `owc_marts`
still holds the last known-good data, and **the suspect rows are sitting in
`owc_staging` on purpose** so you can look at them.

**Diagnose.** The log line names the check, what was observed, and what was
expected:

```bash
gcloud logging read \
  'resource.type="cloud_run_job" jsonPayload.event="quality_check_failed"' \
  --project=$PROJECT --limit=20 \
  --format='table(jsonPayload.dataset,jsonPayload.check,jsonPayload.observed,jsonPayload.expected,jsonPayload.detail)'
```

Then diff staging against what is published:

```bash
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT
   (SELECT COUNT(*) FROM `owc_staging.THE_TABLE`) AS staging_rows,
   (SELECT COUNT(*) FROM `owc_marts.THE_TABLE`)   AS published_rows'
```

**Fix, by check:**

| Check | What it means | What to do |
|---|---|---|
| `empty_result` | The query returned zero rows | Run the SQL by hand against Snowflake. Usually a source table went empty or a filter changed. If zero rows is genuinely valid for this dataset, add it to an `allow_empty` list. |
| `known_row_count` | An exact count moved, e.g. `dim_area != 79` | Either Oklahoma gained a county or the query broke. Verify before touching `pipelines.yml` — that literal is there to make you check. |
| `row_count_drift` | Row count moved > 20% vs the previous run | Compare staging to marts. A real seasonal shift is fine; raise the threshold for that dataset. A 90% drop is a broken join. |
| `max_year_regressed` | `max(YEAR)` went **backwards** | See [the stale-year procedure](#stale-year-literals) below. |
| `not_null` | A column that must never be null has nulls | Query the nulls in staging. A newly-null column usually means a renamed source column now joining to nothing. |

**To publish anyway** — only after you have confirmed the data is actually
fine:

```bash
bq cp -f $PROJECT:owc_staging.THE_TABLE $PROJECT:owc_marts.THE_TABLE
```

---

## ALERT 5: row count or max(YEAR) drifted {#alert-5-drift}

**Symptom.** A narrower form of alert 4, fired specifically on
`row_count_drift` or `max_year_regressed`.

**This is the smoke detector for the known stale-year-literal risk.** See
[ADR-005 / accepted risk 1](01-architecture.md#accepted-risks).

### Stale year literals {#stale-year-literals}

Two families of queries have years written into them:

| File | What is hardcoded |
|---|---|
| `sql/owc/fact_regional_indicators.sql` | `YEAR = 2025` (current), `2024` (prior), and `2024`/`2023` for population |
| `sql/owc/fact_emp_county_idx.sql`, `fact_emp_state_idx.sql`, `fact_jobs_county_idx.sql`, `fact_jobs_state_idx.sql` | a 2015 index baseline |

**The symptom of staleness is a table whose `max(YEAR)` stops advancing while
the calendar does not.** That produces wrong-but-plausible numbers, which no
null check would catch.

**Fix.** Check what years the source actually has, then update the literal:

```sql
-- against Snowflake
SELECT MAX(YEAR) FROM LIGHTCAST.TULSA_FOR_YOU.DAT_LABOR_FORCE;
SELECT MAX(YEAR) FROM LIGHTCAST.TULSA_FOR_YOU.DAT_DEMOG;
```

Edit the literal in the `.sql` file, open a PR, and re-run that one dataset.
This is the only place in this repo where editing the Lightcast SQL is the
expected fix rather than a scope violation.

---

## ALERT 6: enrollment scrape found nothing {#alert-6-no-files}

**Symptom.** Discovery matched zero files. Exit code 4.

**This is what Oklahoma redesigning their page looks like, and it is the most
likely failure this pipeline will ever have.** It is expected eventually, not
a surprise.

**Diagnose — start from the snapshot, not the code.** Every run saves the page
before parsing it:

```bash
RAW=okw-raw-$ENV
gcloud storage ls gs://$RAW/enrollment/page_snapshots/ | sort | tail -5

# Pull the failing run and the last good one, and diff them
gcloud storage cp gs://$RAW/enrollment/page_snapshots/BAD_RUN_ID.html  /tmp/bad.html
gcloud storage cp gs://$RAW/enrollment/page_snapshots/GOOD_RUN_ID.html /tmp/good.html
diff <(python3 -c "import sys,re;print(re.sub(r'>\s*<','>\n<',open(sys.argv[1]).read()))" /tmp/good.html) \
     <(python3 -c "import sys,re;print(re.sub(r'>\s*<','>\n<',open(sys.argv[1]).read()))" /tmp/bad.html) \
     | head -60
```

**Then check which selector broke.** These are the four things the scraper
depends on, all at the top of
[`scrape.py`](../src/owcdata/pipelines/enrollment/scrape.py):

| Constant | Current value | What breaks it |
|---|---|---|
| `GRID_WRAPPER_CLASSES` | `aem-Grid aem-Grid--12 aem-Grid--default--12` | A CMS upgrade or a template change |
| `CONTAINER_CLASS` | `aem-GridColumn--default--12` | Same |
| `SCHOOL_ETHGEN_LI_TEXT` | `School Site Totals w/Ethnicity and Gender` | Someone rewording the link |
| `SCHOOL_TOTALS_SHEET` | `School Totals by Race` | A renamed worksheet |

```bash
# Which one is missing from the new page?
grep -c 'aem-Grid--default--12' /tmp/bad.html
grep -io 'School Site Totals[^<]*' /tmp/bad.html | sort -u
```

**Fix.**

1. Save the new page as a test fixture — this is the important step, because
   it turns the fix into a test:
   ```bash
   cp /tmp/bad.html tests/fixtures/enrollment/page.html
   ```
2. Run the parsing tests. They will fail, and *how* they fail tells you what
   changed:
   ```bash
   make test
   ```
3. Update the selector constants until they pass.
4. Open a PR. The fixture goes in with it, so this exact regression is now
   covered.

**If the page is merely restructured but the links are still findable,** you
may instead see a `grid_wrapper_not_found` warning with a successful run — the
scraper falls back to a whole-page search. That is a warning, not a failure,
and it is your advance notice that the selectors are drifting. Fix it before
it becomes alert 6.

---

## ALERT 7: enrollment workbook skipped {#alert-7-reshape-skipped}

**Symptom.** A workbook was found but could not be reshaped, so its fiscal
year is missing from the merged output. Exit code 5.

Related: `alert-7b-unreadable` / `no_matching_sheet` means the workbook
downloaded but no sheet matched a known column signature.

**Diagnose.** The raw workbook is archived, so you can open the exact file
that failed:

```bash
gcloud logging read \
  'resource.type="cloud_run_job" (jsonPayload.event="workbook_reshape_skipped" OR jsonPayload.event="no_matching_sheet")' \
  --project=$PROJECT --limit=20 --format='value(jsonPayload.detail)'

gcloud storage ls gs://okw-raw-$ENV/enrollment/source_files/
gcloud storage cp gs://okw-raw-$ENV/enrollment/source_files/THE_FILE.xlsx /tmp/
```

```bash
# What sheets and headers does it actually have?
python3 -c "
import pandas as pd, sys
x = pd.ExcelFile('/tmp/THE_FILE.xlsx')
print('sheets:', x.sheet_names)
for s in x.sheet_names[:4]:
    for h in range(6):
        cols = list(pd.read_excel(x, sheet_name=s, header=h, nrows=0).columns)
        print(f'  {s!r} header={h}: {cols[:8]}')
"
```

**Fix.** Compare against the three column naming conventions in `scrape.py`
(`value_columns`, `verbose_to_abbrev_v1`, `verbose_to_abbrev_v2`). Oklahoma has
used three different spellings across fiscal years, so a fourth is entirely
plausible. Add it as `verbose_to_abbrev_v3`, add the workbook as a fixture,
and re-run.

Note that `scrape.py` is **generated**: edit
[`scripts/derive_scrape.py`](../scripts/derive_scrape.py) or the pristine
original, then `make derive-scrape`. Editing `scrape.py` directly will be
caught by `make derive-check` in CI.

---

## ALERT 8: memory {#alert-8-memory}

**Symptom.** A task used more than 85% of its 2 GiB. Cloud Run kills at 100%
with no graceful failure, so this is the warning before a crash that is harder
to read.

**Context.** The Parquet writer streams: measured peak is ~290 MB and is
**flat in result size** — a 1.6 GB and a 3.2 GB result set peak identically.
A task approaching 2 GiB means something is buffering that should be
streaming.

**Diagnose.** Which dataset, and did it crash or just get close?

```bash
gcloud logging read \
  'resource.type="cloud_run_job" ("Memory limit" OR "OOM" OR severity>=ERROR)' \
  --project=$PROJECT --limit=20
```

**Fix, in order of preference:**

1. Lower `ROW_GROUP_TARGET_BYTES` in
   [`lightcast/run.py`](../src/owcdata/pipelines/lightcast/run.py) — 64 MiB
   today; 32 MiB is measurably no worse.
2. Check nothing is writing to local disk. Cloud Run's filesystem is
   **in-memory in both execution generations with no size limit**, so a file
   written to `/tmp` counts against this limit.
3. Only then raise `memory` in the env's `main.tf`. Remember CPU and memory
   are coupled: >4 GiB forces more vCPU.

---

## ALERT 9: cost {#alert-9-cost}

**Symptom.** BigQuery scanned bytes or the billing budget crossed a threshold.

**Context.** The pipeline itself scans very little — loads and table copies are
free, and the quality gate is one scan of staging per dataset. So this is
almost always a reporting query pattern.

**Diagnose.**

```bash
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT user_email, COUNT(*) AS queries,
        ROUND(SUM(total_bytes_billed)/POW(2,30), 1) AS gib_billed
 FROM `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
 WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY)
   AND job_type = "QUERY"
 GROUP BY user_email ORDER BY gib_billed DESC'
```

**Fix.** If `okw-powerbi-*` is the top consumer, PowerBI is on DirectQuery and
is billing a scan per slicer click. Either move the model to Import mode or
set a **custom daily query quota** on that service account. See open item 5 —
Import mode on a Pro workspace caps a semantic model at 1 GB compressed.

---

## Common procedures

### Roll back a published table

Every publish takes a snapshot first.

```bash
# Find the snapshots for a table
bq ls --project_id=$PROJECT owc_ops | grep THE_TABLE

# Restore
.venv/bin/owcdata rollback THE_TABLE $PROJECT.owc_ops.THE_TABLE__RUN_ID
# or:  bq cp -f $PROJECT:owc_ops.THE_TABLE__RUN_ID $PROJECT:owc_marts.THE_TABLE
```

### Re-run one dataset

```bash
gcloud run jobs execute okw-lightcast-$ENV --region=$REGION --project=$PROJECT \
  --args="run,lightcast,--dataset,dim_area" --tasks=1 --wait
```

### Re-run a whole group

```bash
gcloud run jobs execute okw-lightcast-$ENV --region=$REGION --project=$PROJECT \
  --args="run,lightcast,--group,monthly" --tasks=41 --wait
```

### Reprocess enrollment without re-scraping

The originals are archived. Copy them back into the state bucket's cache and
the scraper will reuse them:

```bash
gcloud storage cp "gs://okw-raw-$ENV/enrollment/source_files/*" \
  "gs://okw-enrollment-state-$ENV/data_sources/"
```

### Force the enrollment pipeline to rebuild from scratch

It short-circuits when every source file is already cached. To force a full
rebuild, clear the cache — the originals stay archived in the raw bucket, so
this is recoverable:

```bash
gcloud storage rm "gs://okw-enrollment-state-$ENV/data_sources/**"
gcloud run jobs execute okw-enrollment-$ENV --region=$REGION --project=$PROJECT --wait
```

### Pause everything

```bash
for j in $(gcloud scheduler jobs list --location=$REGION --project=$PROJECT --format='value(name)'); do
  gcloud scheduler jobs pause "$j" --location=$REGION --project=$PROJECT
done
```

Expect [alert 2](#alert-2-didnt-run) to fire once the grace period elapses.
That is the alert working.

### Rotate the Snowflake password

```bash
printf '%s' 'NEW_PASSWORD' | \
  gcloud secrets versions add okw-snowflake-password-$ENV --data-file=- --project=$PROJECT
```

The job reads `version = "latest"`, so the next run picks it up. Verify before
the next scheduled run:

```bash
gcloud run jobs execute okw-lightcast-$ENV --region=$REGION --project=$PROJECT \
  --args="run,lightcast,--dataset,dim_area,--limit,10" --tasks=1 --wait
```

### Verify the IAM separation still holds

Phase 2's acceptance check, worth repeating after any IAM change:

```bash
# The enrollment SA must NOT be able to read the Snowflake secret.
gcloud secrets get-iam-policy okw-snowflake-password-$ENV --project=$PROJECT \
  --format=json | grep -q "okw-enrollment-$ENV" \
  && echo "PROBLEM: enrollment can read the Snowflake secret" \
  || echo "OK: enrollment has no access to the Snowflake secret"

# PowerBI must have NO grant on owc_marts.
bq show --format=prettyjson $PROJECT:owc_marts | grep -q "okw-powerbi-$ENV" \
  && echo "PROBLEM: PowerBI has a direct grant on owc_marts" \
  || echo "OK: PowerBI reads only through authorized views"
```
