# Runbook

One entry per alert: symptom → diagnosis → fix. Start with the alert you got.

**Set these once per shell:**

```bash
export ENV=dev                      # or prod
export PREFIX=owc-dpar-d            # or owc-dpar-p  — matches name_prefix in tfvars
export PROJECT=$PREFIX              # project id and name_prefix are the same value
export REGION=us-central1
```

Resource names follow the OMES convention
`<type>-<name_prefix>-<qualifier>-<seq>`, so the commands below build them
from `$PREFIX`: `cr-$PREFIX-lightcast-1`, `gs://gcs-$PREFIX-raw-1`, and so
on. See [`modules/platform/naming.tf`](../infra/terraform/modules/platform/naming.tf).

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

Open **`owc_ops.pipeline_runs_recent`** — a view over `pipeline_runs` ordered
newest-first, so it needs no `ORDER BY`:

```bash
bq head -n 20 --project_id=$PROJECT owc_ops.pipeline_runs_recent
```

(A BigQuery table has no inherent row order; the console's preview shows
storage order, which is why the view exists.)

Or query it directly:

```bash
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT started_at, pipeline, dataset, status, row_count, duration_seconds,
        LEFT(error, 200) AS error
 FROM `owc_ops.pipeline_runs_recent`
 WHERE started_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
 LIMIT 40'
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
gcloud run jobs execute cr-$PREFIX-lightcast-1 --region=$REGION --project=$PROJECT \
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

**Prod only.** Dev's schedulers are paused and its freshness check is off
(`freshness_check_enabled = false`), because dev only runs when someone
deploys — so "nothing ran this month" is dev working as intended, not a
fault. If you are seeing this in dev, something re-enabled it.

**Diagnose.**

```bash
# What is overdue
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT * FROM `owc_ops.dataset_freshness` ORDER BY days_since_success DESC LIMIT 20'

# Is the scheduler even enabled?
gcloud scheduler jobs list --location=$REGION --project=$PROJECT
gcloud scheduler jobs describe cs-$PREFIX-lightcast-monthly-1 --location=$REGION --project=$PROJECT
```

**Fix, by cause:**

| Cause | Fix |
|---|---|
| Scheduler is PAUSED **in prod** | `gcloud scheduler jobs resume cs-$PREFIX-lightcast-monthly-1 --location=$REGION` |
| Scheduler is PAUSED **in dev** | Expected — do not resume. Dev's schedulers are paused by Terraform (`schedulers_paused = true`) so dev does not re-run prod's 41 Snowflake queries and bill Lightcast twice. This alert is also disabled in dev, so you should not be reading this there. |
| Scheduler was deleted | `make tf-apply ENV=$ENV` |
| Scheduler fires but jobs never start | That is [alert 3](#alert-3-scheduler-failing) |
| Jobs run but the manifest is empty | Check for `manifest_write_failed` in the logs — the run may be fine while the record-keeping is broken, which disables this alert. Verify `bigquery.dataEditor` on `owc_ops`. |

Then catch up manually:

```bash
gcloud run jobs execute cr-$PREFIX-lightcast-1 --region=$REGION --project=$PROJECT \
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
   gcloud scheduler jobs describe cs-$PREFIX-lightcast-monthly-1 \
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
RAW=gcs-$PREFIX-raw-1
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

## ALERT 6b: enrollment page structure drifted {#alert-6b-page-drift}

**Symptom.** `grid_wrapper_not_found`, and **the run succeeded.** The scraper
could not find Oklahoma's `aem-Grid` wrapper, fell back to searching the whole
page, and found the links anyway.

Nothing is broken yet. This is the early warning before
[alert 6](#alert-6-no-files) — the page has been restructured and the
selectors are drifting. The next change is likely to break discovery outright.

**Diagnose.** Diff this run's snapshot against the previous one:

```bash
RAW=gcs-$PREFIX-raw-1
gcloud storage ls gs://$RAW/enrollment/page_snapshots/ | sort | tail -2
gcloud storage cp gs://$RAW/enrollment/page_snapshots/OLD.html /tmp/old.html
gcloud storage cp gs://$RAW/enrollment/page_snapshots/NEW.html /tmp/new.html
diff <(python3 -c "import sys,re;print(re.sub(r'>\s*<','>\n<',open('/tmp/old.html').read()))") \
     <(python3 -c "import sys,re;print(re.sub(r'>\s*<','>\n<',open('/tmp/new.html').read()))") | head -40
```

**Fix.** Same procedure as alert 6, but unhurried: save the new HTML over
`tests/fixtures/enrollment/page.html`, run `make test`, and update the
selector constants until the assertions pass. The fixture goes in with the
PR, so the regression is covered from then on.

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

gcloud storage ls gs://gcs-$PREFIX-raw-1/enrollment/source_files/
gcloud storage cp gs://gcs-$PREFIX-raw-1/enrollment/source_files/THE_FILE.xlsx /tmp/
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

**Fix.** If `sa-*-powerbi-1` is the top consumer, PowerBI is on DirectQuery and
is billing a scan per slicer click. Either move the model to Import mode or
set a **custom daily query quota** on that service account. See open item 5 —
Import mode on a Pro workspace caps a semantic model at 1 GB compressed.

---

## First-deploy failures

These are ordering problems on a brand-new project, not broken config. Full
sequence: [`03-gcp-setup.md`](03-gcp-setup.md).

### `name unknown: Repository "ar-$PREFIX-images-1" not found`

The Docker build succeeded and the **push** failed. Terraform creates the
Artifact Registry repository, so it has to exist before the first build:

```bash
make tf-bootstrap ENV=$ENV     # creates the platform, incl. the registry
make build ENV=$ENV
```

`tf-bootstrap` applies only `module.platform` and creates no Cloud Run job. It
passes a placeholder digest itself, purely to satisfy the pipeline module's
digest validation — Terraform evaluates variable validation even for resources
`-target` excludes.

### `PERMISSION_DENIED: The caller does not have permission` on `gcloud builds submit`, as project owner

Not an IAM problem. Enabling `cloudbuild.googleapis.com` provisions the Cloud
Build service agent asynchronously, and submits are rejected until it lands.

```bash
# Confirm the agent exists
gcloud projects get-iam-policy $PROJECT \
  --flatten="bindings[].members" \
  --filter="bindings.members:cloudbuild" --format="value(bindings.members)"
```

Wait ~30 seconds and re-run. Doing `make tf-bootstrap` first avoids this,
because Terraform enables the API well before you build.

### `Failed to get existing workspaces: ... storage: bucket doesn't exist` on `terraform init`

**The bucket almost certainly does exist.** This message is a 404 from GCS
surfacing with the wrong explanation.

gcloud and Terraform authenticate **differently**: the CLI uses the account
from `gcloud auth login`, Terraform uses Application Default Credentials. If
ADC carries a `quota_project_id` that is deleted or inactive, every GCS call
is billed to a project that cannot be resolved and returns
`404 The requested project was not found` — which the GCS backend reports as
the bucket not existing.

Diagnose:

```bash
# What quota project is ADC billing to?
python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/gcloud/application_default_credentials.json'))).get('quota_project_id','(none)'))"

# Is it actually usable? `describe` exits 0 even for DELETE_REQUESTED,
# so check the state, not the exit code.
gcloud projects describe THAT_PROJECT --format='value(lifecycleState)'
```

Anything other than `ACTIVE` is the cause. Fix:

```bash
gcloud auth application-default set-quota-project $PROJECT
```

Confirm — note this must send the quota-project header, because that is what
the client library does and it is the whole failure mode:

```bash
TOK=$(gcloud auth application-default print-access-token)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
  "https://storage.googleapis.com/storage/v1/b/gcs-owc-dpar-d-tfstate-1/o?prefix=env&maxResults=1"
# 200
```

`make iam-check` runs exactly this check and fails with the
specific fix, so a fresh machine hits a one-line error instead of this.

**Also check `core.project`.** If `gcloud config list` shows an unrelated
project, any command where you forget `--project` goes somewhere unexpected:

```bash
gcloud config set project $PROJECT
```

### `key "_X" in the substitution data is not matched in the template`

Cloud Build requires every key passed with `--substitutions` to be
**referenced** in `docker/cloudbuild.yaml`. Declaring it in the
`substitutions:` block is not enough.

Note also that built-in substitutions (`SHORT_SHA`, `COMMIT_SHA`,
`BRANCH_NAME`) are only populated for trigger-started builds, never for
`gcloud builds submit` — which is why the tag here is the user-defined `_TAG`.

```bash
# Every key used anywhere must resolve
grep -o '\${_[A-Z_]*}' docker/cloudbuild.yaml | sort -u
```

### `Error: Invalid value for variable` on `image_digest`

The pipeline module rejects a tag and requires `...@sha256:<64 hex>`, so a
rollback is a revert rather than a race against a moving tag.

```bash
make image-digest ENV=$ENV      # prints the correct, digest-pinned reference
```

### `Secret projects/.../secrets/sm-<name_prefix>-snowflake-password-1/versions/latest was not found`

The secret **container** exists but has no **version**. Terraform creates the
container and never the value — deliberately, so the password stays out of
Terraform state — but `versions/latest` cannot resolve to nothing, so the
lightcast job fails to create.

Note the enrollment job creates fine in this situation. That is the
per-pipeline secret separation working: the scraper reads a public webpage and
is granted no secret access at all.

```bash
# Container present but empty?
gcloud secrets versions list sm-$PREFIX-snowflake-password-1 --project=$PROJECT
```

Fix, then re-apply:

```bash
printf '%s' 'THE_PASSWORD' | \
  gcloud secrets versions add sm-$PREFIX-snowflake-password-1 --data-file=- --project $PROJECT

IMAGE=$(make -s image-digest ENV=$ENV)
make tf-apply ENV=$ENV TF_ARGS="-var=image_digest=$IMAGE"
```

The half-created job is left **tainted** in state, so the next apply replaces
it. Nothing needs to be destroyed or imported:

```bash
terraform state show module.lightcast.google_cloud_run_v2_job.this   # tainted
```

`make tf-apply` now runs `make preflight` first and refuses to start when the
version is missing, so this costs a second instead of failing minutes into an
apply. `SKIP_PREFLIGHT=1 make tf-apply ...` bypasses it.

**After rotating the password**, no apply is needed — the job reads
`versions/latest` at each execution. See
[Rotate the Snowflake password](#rotate-the-snowflake-password).

### `Service account service-<num>@gcp-sa-<service>.iam.gserviceaccount.com does not exist`

**Enabling an API does not create its service agent.** The agent is
provisioned the first time the service is actually used, so granting a role to
a hand-constructed agent address right after `google_project_service` fails.

Terraform handles this with `google_project_service_identity`, which forces the
agent into existence and returns its real email. That resource has **no GA
equivalent**, which is the only reason the `google-beta` provider is declared
in this repo:

```hcl
resource "google_project_service_identity" "bigquerydatatransfer" {
  provider   = google-beta
  project    = var.project_id
  service    = "bigquerydatatransfer.googleapis.com"
  depends_on = [google_project_service.enabled]
}
```

If you add a resource that grants a role to another Google service agent, use
the same pattern and reference `.member` rather than building the address from
the project number.

```bash
# Which service agents currently exist in the project?
gcloud projects get-iam-policy $PROJECT --flatten='bindings[].members' \
  --filter='bindings.members:gcp-sa-' --format='value(bindings.members)' | sort -u
```

### `Cannot find metric(s) that match type = "logging.googleapis.com/user/..."` — 404 on an alert policy

A log-based metric is visible to the **Logging** API the moment Terraform
creates it, but takes time to appear as a **Monitoring** metric descriptor.
Until it does, creating an alert policy that references it 404s. The API says
so in the error: *"If a metric was created recently, it could take up to 10
minutes to become available."*

`depends_on` does not help — the metric genuinely exists, it is just not
queryable yet. Only elapsed time fixes it.

**Just re-run the apply.** Terraform is idempotent here, and the metrics will
have propagated by then:

```bash
IMAGE=$(make -s image-digest ENV=$ENV)
make tf-apply ENV=$ENV TF_ARGS="-var=image_digest=$IMAGE"
```

Both modules now insert a `time_sleep` (`metric_propagation_wait`, default
`90s`) between metric creation and alert-policy creation, so a fresh project
should not hit this. It waits on **create only**, so it costs nothing on later
applies, and its `triggers` are keyed on the metric ids — so adding a new
event alert later waits again instead of racing.

If an apply still races, raise it:

```bash
make tf-apply ENV=$ENV TF_ARGS="-var=image_digest=$IMAGE -var=metric_propagation_wait=180s"
```

Confirm what Monitoring can actually see:

```bash
TOK=$(gcloud auth application-default print-access-token)
curl -s -H "Authorization: Bearer $TOK" \
  "https://monitoring.googleapis.com/v3/projects/$PROJECT/metricDescriptors?filter=metric.type%3Dstarts_with(%22logging.googleapis.com%2Fuser%2Fowc%22)" \
  | python3 -c "import json,sys;[print(m['type']) for m in json.load(sys.stdin).get('metricDescriptors',[])]"
```

Compare against `gcloud logging metrics list --project=$PROJECT`. Metrics in
the second list but not the first are still propagating.

### `google_cloud_scheduler_job` shows a pending `retry_config { retry_count = 0 }`

Not a problem, and not perpetual. GCP omits `retryCount` from the API response
when it is zero, so Terraform sees the block as missing and plans to add it.
One apply reconciles it.

**Retries are off either way** — an absent `retryCount` *is* zero, which is
what this design requires because `jobs:run` is not idempotent: a transient
503 with retries enabled can start two executions for one `run_date`, and for
lightcast that means re-querying and re-billing Lightcast's warehouse twice.

```bash
# Verify no retries, on either scheduler
gcloud scheduler jobs describe cs-$PREFIX-lightcast-monthly-1 --location=$REGION \
  --project=$PROJECT --format='yaml(retryConfig)'
# no retryCount field, or retryCount: 0 -> correct
```

### `The supplied filter does not specify a valid combination of metric and monitored resource descriptors`

An alert policy names a metric with the wrong monitored resource. The pairing
is not guessable — confirm it against a live project:

```bash
TOK=$(gcloud auth application-default print-access-token)
curl -s -H "Authorization: Bearer $TOK" \
  "https://monitoring.googleapis.com/v3/projects/$PROJECT/metricDescriptors?filter=metric.type%3Dstarts_with(%22bigquery.googleapis.com%2Fquery%22)" \
  | python3 -c "import json,sys;[print(m['type'], m.get('monitoredResourceTypes')) for m in json.load(sys.stdin)['metricDescriptors']]"
```

The pairing that bit this repo: `query/scanned_bytes_billed` is reported
against **`global`**, not `bigquery_project`. The verified table is in
[`07-monitoring.md`](07-monitoring.md#metric-type-strings).

Note this error is the *good* case — it fails at apply. A metric type that is
merely misspelled applies cleanly and then never fires.

### The first apply wants to create nothing, or errors on a missing API

`google_project_service` needs Service Usage and Cloud Resource Manager to
already be on — Terraform cannot enable the APIs that let it enable APIs. Run
`make gcloud-admin ENV=$ENV` first.

## The smoke test "succeeded" but there is no data in owc_marts

That is correct behavior, not a failure. A `--limit N` run is a deliberate
truncation of the real result, so it **never publishes** — copying a sample
over a production marts table would be worse than not running at all.

Look for this in the logs:

```text
publish_skipped_row_limited  rows=78
pipeline_succeeded
```

and for `status = 'success_limited'` in `owc_ops.pipeline_runs`. That status
is deliberately excluded from `previous_successful()`, so a smoke run cannot
poison the quality baseline that the next real run is compared against.

To actually populate marts, run without `--limit`. Use a small dimension if
you just want to prove the publish path:

```bash
gcloud run jobs execute cr-$PREFIX-lightcast-1 --region $REGION --project $PROJECT \
  --args="run,lightcast,--dataset,dim_area" --tasks=1 --wait
```

## `make which-image` shows "newest build: <none>"

There is no image tagged with the current git short SHA. The usual cause is
committing **after** building: `make build` tags the image with the SHA that
was checked out at the time, and HEAD has since moved.

`make image-digest` now falls back to `:latest` and warns on stderr, so the
dev loop keeps working. To get back to a state where the tag identifies the
commit:

```bash
make deploy ENV=$ENV      # build at this commit, then point the jobs at it
```

Keeping tag and commit aligned matters because a digest is how a rollback is
identified — see [`04-deployment.md`](04-deployment.md#rolling-back).

## A fix was deployed but the old behavior persists

**The jobs are probably still running the previous image.** A Cloud Run job
pins an image **digest**, and `image` is in `lifecycle.ignore_changes` on the
job resource — so neither `make build` nor `terraform apply` will move a job
onto a newly built image. `make build` pushes to the registry and stops there.

This is silent in a specific way: rebuilding at the same git SHA reuses the
tag, so `:<sha>` moves to the new digest while the job keeps pinning the old
one. The registry looks updated; the job is not.

```bash
make which-image ENV=$ENV
```

```text
  newest build      : ...owcdata@sha256:f79b1fb2...
  cr-owc-dpar-d-lightcast-1 : ...owcdata@sha256:a217ebdb...   <- stale
  cr-owc-dpar-d-enrollment-1: ...owcdata@sha256:a217ebdb...   <- stale
```

Fix:

```bash
make set-image ENV=$ENV
```

Use `make deploy ENV=$ENV` to build and set the image in one step, which is
the loop to prefer while iterating.

**Why `ignore_changes` is there at all:** during an incident someone will run
`gcloud run jobs update --image` to pin an older build. Without it, the next
unrelated `terraform apply` would silently revert that. The cost is that
deploying an image is an explicit step — hence `set-image`.

## A make target says a resource is missing, but it exists

**Check the gcloud CLI token first.** Every "does this exist?" check in the
Makefile runs a gcloud command, and an expired token looks identical to an
absent resource. Two real examples of the same root cause:

```text
no image found at .../owcdata:585e9f2 or :latest.  Build one first
The secret container sm-owc-dpar-d-snowflake-password-1 does not exist yet
```

Both were false. The image had three tags and the secret returned HTTP 200.

```bash
make auth-check ENV=dev        # what the other targets now run first
gcloud auth login              # the usual fix
```

**gcloud CLI credentials and Application Default Credentials are separate.**
Terraform uses ADC and keeps working while the CLI is expired, which is what
makes this confusing — `terraform plan` succeeds while `make build` insists
nothing exists. If Terraform fails too:

```bash
gcloud auth application-default login
```

`auth-check` is now a prerequisite of `build`, `image-digest`, `set-image`,
`which-image` and `preflight`, so the expired-token case reports itself
instead of being misattributed.

To confirm a resource independently of the CLI, query the API with an ADC
token:

```bash
TOK=$(gcloud auth application-default print-access-token)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOK" \
  "https://secretmanager.googleapis.com/v1/projects/$PROJECT/secrets/sm-$PREFIX-snowflake-password-1"
```

## CI/CD failures

> **Most of this section is dormant.** `enable_wif = false` in both
> environments, so GitHub Actions does not deploy and nothing runs as a
> deployer service account. Deploys run from Cloud Shell, as you — see
> [`09-gcloud-deploy.md`](09-gcloud-deploy.md). The build entries below still
> apply, because `make build` submits the same Cloud Build either way.
>
> For failures on the current path, see
> [Cloud Shell and the reduced permission set](#cloud-shell-and-the-reduced-permission-set).


### CI: `The interpreter at /usr is externally managed`

`uv pip install --system` targets the runner's system Python, which is PEP 668
externally-managed on Ubuntu. Install into a venv and put it on `PATH`, which
is also what `make setup` does locally:

```yaml
- run: |
    uv venv --python 3.12
    echo "$PWD/.venv/bin" >> "$GITHUB_PATH"
    uv pip install -e ".[dev]"
```

### Build: `sa-<name_prefix>-build-1@... does not have storage.objects.get access` to the source tarball

Almost always **IAM propagation**, not a missing grant. The build SA holds
`roles/storage.objectViewer` at project level, which covers the
`gs://<project>_cloudbuild` bucket `gcloud builds submit` uploads to — but a
project-level grant takes 1–2 minutes to take effect (GCP documents up to
seven), and a build started immediately after `terraform apply` can beat it.

Confirm the grant exists, then retry:

```bash
gcloud projects get-iam-policy $PROJECT --flatten='bindings[].members' \
  --filter="bindings.members:sa-$PREFIX-build-1" --format='table(bindings.role)'
# expect: roles/logging.logWriter, roles/storage.objectViewer

make deploy ENV=$ENV
```

If it persists past a few minutes, the grant is genuinely missing —
`terraform apply` did not run, or ran without the build-SA resources:

```bash
cd infra/terraform/envs/$ENV && terraform state list | grep build
# expect: google_service_account.build, build_log_writer,
#         build_source_reader, build_writer, and the deployer's act_as
```

**On the project-level grant.** Scoping it to the `_cloudbuild` bucket would
be tighter, but that bucket is created by `gcloud builds submit` itself, so a
bucket-scoped grant cannot exist before the first build. It is read-only
object access, held by an identity only the deployer can assume, in a project
where the deployer already has `storage.admin` — so it widens nothing in
practice. The tighter alternative is `--gcs-source-staging-dir` pointed at a
Terraform-managed bucket, which would also need that bucket created during
bootstrap.

Note that `uniform_bucket_level_access: False` on the `_cloudbuild` bucket is
not the cause — legacy ACLs are additive and do not override an IAM grant.

### Deploy: `caller does not have permission to act as service account .../<numeric id>`

Submitting a Cloud Build requires `iam.serviceAccountUser` on the identity the
build runs as. Without an explicit one, that is the **Compute Engine default**
service account — which carries project Editor, so granting the deployer
`actAs` on it would be a privilege-escalation path rather than a fix.

Instead, builds run as `sa-<name_prefix>-build-1`, named by the `_BUILD_SA`
substitution in `docker/cloudbuild.yaml`. To resolve a numeric id from an
error like this:

```bash
TOK=$(gcloud auth application-default print-access-token)
curl -s -H "Authorization: Bearer $TOK" \
  "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts?pageSize=100" \
  | python3 -c "import json,sys;[print(a['uniqueId'], a['email']) for a in json.load(sys.stdin)['accounts']]"
```

Note that specifying a build service account **requires**
`options.logging: CLOUD_LOGGING_ONLY` — a build with its own service account
cannot use Cloud Build's default logging behavior.

### Reading a failed run

```bash
gh run list --limit 5
gh run view <id> --json name,jobs \
  -q '.jobs[] | "\(.name) -> \(.conclusion)", (.steps[] | select(.conclusion=="failure") | "   FAILED: \(.name)")'
gh run view <id> --log 2>&1 | grep -iE 'error|denied|not found' | head
```

`--log-failed` returns the whole failed job including its cleanup, so the real
error is usually buried; grepping `--log` for `error|denied` finds it faster.

## WIF and outputs

> Everything from [GitHub Actions deploys fail to
> authenticate](#github-actions-deploys-fail-to-authenticate-via-wif) onward
> needs `enable_wif = true`, which neither environment sets today. The first
> two entries apply on any path.


### `terraform output` says "No outputs found"

You are almost certainly in the repo root. Terraform outputs live in the env
directory, and every `make tf-*` target cds there for you:

```bash
make tf-output ENV=$ENV
```

Add `NAME=<output>` for a single raw value:

```bash
make tf-output ENV=$ENV NAME=lightcast_job
```

`wif_attribute_condition`, `workload_identity_provider` and
`deployer_service_account` print **nothing** today: `enable_wif = false`, so
the module producing them is not instantiated and `one(module.wif[*]...)`
yields null. That is correct, not a missing output.

### A pasted `#` line errors in zsh

If you copy a command *and* the expected-output line beneath it, zsh may try
to run the comment:

```text
zsh: = not found
```

zsh does not treat `#` as a comment on an interactive command line unless
`interactive_comments` is set, and a word beginning with `=` then triggers
EQUALS expansion — zsh looks for a command literally named `=`. Nothing ran
and nothing is broken; the command on the line above it succeeded.

Paste one line at a time, or turn comments on permanently:

```bash
echo 'setopt interactive_comments' >> ~/.zshrc
```

The docs here keep expected output in separate `text` blocks rather than `#`
comments for this reason.



### A YAML snippet pasted into the shell errors

```text
zsh: command not found: name:
zsh: command not found: run:
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
```

You pasted GitHub Actions YAML into a terminal. It is not shell, and the
`ACTIONS_ID_TOKEN_REQUEST_*` variables exist only inside a runner with
`id-token: write` — so `curl` returned nothing and Python got empty input.
Nothing ran and nothing is broken.

Blocks tagged `yaml` in these docs belong in a workflow file. Only `bash`
blocks are meant to be run.

### GitHub Actions deploys fail to authenticate via WIF

The usual cause is the `attribute_condition` not matching the repository
string GitHub actually sends. `assertion.repository` preserves the owner's
**exact casing** and the comparison is case-sensitive, so `intulsa/repo` never
matches `inTulsa/repo`.

It fails **closed** — no security hole, just no deploys — which is why it can
sit unnoticed.

```bash
make wif-check ENV=$ENV      # compares tfvars against the git remote
make tf-output ENV=$ENV NAME=wif_attribute_condition
```

`make tf-apply` runs `wif-check` as part of `preflight`, so a mismatch blocks
the apply rather than shipping a condition that cannot match.

Other things to check, in order:

1. **`allowed_refs`.** Prod pins `refs/heads/prod`, so a branch or a fork's
   pull request cannot deploy there. That is intentional — confirm the
   workflow is running on the `prod` branch.
2. **The repository variables.** `WIF_PROVIDER_<ENV>` and
   `DEPLOYER_SA_<ENV>` must match `make tf-output`.
3. **`id-token: write`** permission on the workflow job. Without it GitHub
   never mints a token at all.

Changing `github_repository` replaces
`module.wif.google_service_account_iam_member.github_may_impersonate`, because
the repository is embedded in its `principalSet` member string. That
replacement is expected and safe.

### `Backend configuration changed` after pointing at a different project

```text
Error: Backend configuration changed

A change in the backend configuration has been detected, which may require
migrating existing state.
```

Terraform caches the backend config in `.terraform/`, so editing the bucket
in `backend.tf` invalidates it. **A fresh clone never sees this** — there is
no cache to invalidate — so it is a working-copy problem, not a setup one.

**Take `-reconfigure`, not the `-migrate-state` the error suggests first.**

```bash
make tf-reinit ENV=$ENV
```

`-migrate-state` copies the OLD project's state into the NEW bucket. Terraform
then believes the old project's resources exist in the new project and plans
against them — deleting and recreating things that were never there. It is the
right flag for moving one environment's state to a new bucket, and the wrong
one for pointing a working copy at a different environment.

Each environment already keeps its state in its own bucket, so switching
projects means adopting that bucket as it is. `tf-reinit` prints the resource
count afterwards; `0` is correct for a project you have not applied to yet.

### GitHub Actions authenticates fine, then the apply 403s

A different failure with a similar smell. The `auth` step is green, the build
succeeds, and `terraform apply` dies during **refresh** with a wall of
near-identical errors:

```text
Error when reading or editing Resource "project \"owc-dpar-d\"" with IAM Member:
Role "roles/storage.admin" Member "serviceAccount:sa-owc-dpar-d-deployer-1@...":
Error retrieving IAM policy for project "owc-dpar-d":
googleapi: Error 403: The caller does not have permission, forbidden
```

```text
Permission 'iam.workloadIdentityPools.get' denied on resource
'//iam.googleapis.com/projects/.../workloadIdentityPools/wip-owc-dpar-d-github-1'
```

**WIF is not the problem** — assuming the deployer worked. The deployer is
missing permissions once assumed.

The misleading part is that each error names the role being *granted*
(`roles/storage.admin`, etc.), which the deployer already has. The role that
is *missing* is never named. Every `google_project_iam_member` read-modify-
writes the project IAM policy, so all 22 of them fail on the same absent
`resourcemanager.projects.getIamPolicy`.

```bash
make deployer-check ENV=$ENV
```

That names the missing roles directly. The usual answers are
`roles/resourcemanager.projectIamAdmin` and
`roles/iam.workloadIdentityPoolAdmin` — neither is implied by the resource
admin roles, and `serviceAccountAdmin` grants no `workloadIdentityPools`
permissions at all.

Both are declared in `modules/wif/main.tf`, so the fix is an apply run as a
project owner — the deployer cannot grant itself the permission it needs to
make the grant:

```bash
make tf-apply ENV=$ENV TF_ARGS="-var=image_digest=$(make -s image-digest ENV=$ENV)"
make deployer-check ENV=$ENV      # confirm, then re-run the failed workflow
```

Nothing is half-applied when this happens: refresh fails before the plan, so
the run changes nothing. Re-running after the fix is safe.

**Why it never failed locally:** `make tf-apply` run by hand runs as you,
and you are project owner. Only CI runs as the deployer.

#### The other shape: `lacks IAM permission "iam.serviceAccounts.actAs"`

```text
Error 403: The principal (user or service account) lacks IAM permission
"iam.serviceAccounts.actAs" for the resource
"sa-<prefix>-scheduler-1@<project>.iam.gserviceaccount.com"
```

Same cause, different permission. Attaching a service account to a
resource requires `actAs` **on that account** — a per-service-account
binding, not a project role — so the project-role list can be complete and
this still fails. Terraform attaches one in three places:

| File | Field | Identity |
|---|---|---|
| `modules/pipeline/job.tf` | `service_account` | lightcast, enrollment |
| `modules/pipeline/scheduler.tf` | `service_account_email` | scheduler |
| `modules/platform/monitoring.tf` | `service_account_name` | freshness |

plus the build identity, which `gcloud builds submit` runs as. All five must
appear in `impersonatable_service_accounts` in the environment's `main.tf`.

`make deployer-check` verifies both halves — the project roles and the
actAs bindings — and parses the expected accounts out of that list, so
adding one cannot leave the check behind.

Note the freshness grant is **prod-only in practice**: dev sets
`freshness_check_enabled = false`, so the resource is never created there
and a missing grant cannot surface until prod.

## Cloud Shell and the reduced permission set

The failure modes created by moving identities and project IAM out of
Terraform. All of them are permission or ordering problems, and all of them
are answered by the same first command:

```bash
make iam-check ENV=$ENV
```

### `Error 403: ... does not have <some>.<permission> access`, during apply

The Terraform principal is missing one of the ten resource-admin roles. This
is now the *normal* shape of a permission failure: nobody runs as owner any
more, so a missing role shows up as a 403 on one resource type rather than
never showing up at all.

`iam-check` names the exact role, because it parses the expected list from
`infra/gcloud/names.sh` rather than repeating it:

```text
  PROBLEM  MISSING roles/cloudscheduler.admin — terraform apply will 403 on
           the resources it covers
```

Fix by re-running the privileged step — it is idempotent, and grants only what
is missing:

```bash
make gcloud-admin ENV=$ENV
```

If you no longer hold `projectIamAdmin` yourself, send OMES the one command
`iam-check` printed. That is the whole point of the split: this is a
single-line ask, not "give Terraform admin".

### `Error 403: ... lacks IAM permission "iam.serviceAccounts.actAs"`

Attaching a service account to a Cloud Run job, a Scheduler job, a Cloud Build
submission or a BigQuery scheduled query requires `actAs` **on that account**,
which is a per-account binding and invisible in the project IAM policy.

This was previously masked: a human applying as owner has `actAs` on
everything, so the gap only ever appeared in CI. With a reduced principal it
appears immediately, which is better.

`make iam-check` checks all five accounts and names the ones that fail. The
fix is `make gcloud-admin ENV=$ENV`.

### `Error 400: Service account sa-<name_prefix>-<role>-1@... does not exist`

The privileged step has not run in this project, or ran with a different
`name_prefix`. Terraform does not create these any more — it builds the
addresses from `name_prefix` and attaches them.

```bash
make iam-check ENV=$ENV      # says which of the six are missing
make gcloud-admin ENV=$ENV   # creates them
```

A plan cannot catch this: the emails are derived strings, not looked up. That
is deliberate — looking them up would need `iam.serviceAccounts.get` on every
plan, putting an IAM read back into exactly the code path this design removed.
`iam-check` is where the check lives instead, and `make up` runs it first.

### `terraform plan` wants to DESTROY the service accounts

You flipped `manage_identities` to false in a project where Terraform had
already created them, without forgetting them first. Terraform is doing what
it was told: those resources left the configuration, so it wants them gone.

**Do not apply.** Remove them from state — which forgets them, it does not
delete them — using the exact sequence in
[`09-gcloud-deploy.md`](09-gcloud-deploy.md#migrating).

### Cloud Shell disconnected during a `terraform apply`

Sessions end after about 20 minutes idle. Cloud Shell runs inside tmux, so
reattach rather than starting again:

```bash
tmux attach
```

If the apply really did die, the state is **locked** and the next run says so,
naming the lock ID:

```text
Error: Error acquiring the state lock
  ID:        1743...
  Operation: OperationTypeApply
```

Confirm nothing else is running, then release it and re-apply. A half-applied
run re-applied is fine; two applies racing on one state file is not:

```bash
cd infra/terraform/envs/$ENV && terraform force-unlock <ID>
```

### The repo is gone from Cloud Shell

`$HOME` persists between sessions but is deleted after 120 days of inactivity
— a realistic interval for a pipeline that runs monthly. Clone it again:

```bash
cd ~ && git clone https://github.com/inTulsa/owc_okwire_pipeline.git owc
```

Without GitHub access, use the project's own mirror:

```bash
mkdir -p ~/owc && cd ~/owc \
  && gcloud storage cat gs://gcs-$PREFIX-source-1/latest.tar.gz | tar xz
```

If that 404s, nobody has run `make source-push` in this project.
`gcloud storage ls gs://gcs-$PREFIX-source-1/` lists every published revision,
versioned by short SHA, so an older one is always available.

### `NOT_FOUND: Secret [...] not found` when storing the Snowflake password

The secret container was never created, because `terraform apply` never ran —
even though `make tf-bootstrap` printed

```text
>> Artifact Registry and the secret container exist, and the build
   identity can push to the registry.
```

Cloud Shell does not ship terraform. It ships a stub that prints apt install
instructions, and that stub can exit **zero**, so
`terraform init && terraform apply` looks like it succeeded while creating
nothing. The success line above is make's, not terraform's.

```bash
make doctor                  # will now say MISSING terraform
make install-terraform
make up ENV=$ENV             # everything is idempotent; re-run from the top
```

Every `tf-*` target runs `scripts/require-terraform.sh` first, so this cannot
recur silently — "on PATH" is not the test, "reports a version" is. The
guard exists because the first symptom of this was a Secret Manager error
several steps downstream, which points at the wrong component entirely.

### `make build` tags the image `untracked`

The code arrived without `.git`, so `git rev-parse --short HEAD` has no
answer — usually a hand-made tarball. `git clone`, and the tarball
`make source-push` publishes, both include it.

Harmless for the build itself — the image still pushes and
`make image-digest` falls back to `:latest` — but `make which-image` can no
longer tell you which commit a job is running, which matters during an
incident. Re-fetch with `make source-push`'s tarball.

## Common procedures

### Roll back a published table

Every run's Parquet is kept in GCS under its own `run_id`, and the run
manifest records the exact path. Rolling back reloads it — an ordinary load
job, no special permission.

```bash
# What runs are available to roll back to?
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT started_at, run_id, status, row_count, source_uri
 FROM `owc_ops.pipeline_runs_recent`
 WHERE dataset = "THE_TABLE" AND status = "success"
 LIMIT 10'

# Roll back to the run before the current contents
owcdata rollback THE_TABLE

# Or to a specific run
owcdata rollback THE_TABLE --run-id cr-$PREFIX-lightcast-1-abc12
```

Equivalently by hand:

```bash
bq load --replace --source_format=PARQUET \
  $PROJECT:owc_marts.THE_TABLE \
  gs://gcs-$PREFIX-raw-1/lightcast/THE_TABLE/run_id=RUN_ID/THE_TABLE.parquet
```

For a mistake made in the last few days, BigQuery **time travel** is even
simpler and needs nothing:

```bash
bq cp -f "$PROJECT:owc_marts.THE_TABLE@-3600000" $PROJECT:owc_marts.THE_TABLE
```

(`@-3600000` is one hour ago, in milliseconds. The window is 7 days.)

### Re-run one dataset

```bash
gcloud run jobs execute cr-$PREFIX-lightcast-1 --region=$REGION --project=$PROJECT \
  --args="run,lightcast,--dataset,dim_area" --tasks=1 --wait
```

### Re-run a whole group

```bash
gcloud run jobs execute cr-$PREFIX-lightcast-1 --region=$REGION --project=$PROJECT \
  --args="run,lightcast,--group,monthly" --tasks=41 --wait
```

### Reprocess enrollment without re-scraping

The originals are archived. Copy them back into the state bucket's cache and
the scraper will reuse them:

```bash
gcloud storage cp "gs://gcs-$PREFIX-raw-1/enrollment/source_files/*" \
  "gs://gcs-$PREFIX-enrollment-state-1/data_sources/"
```

### Force the enrollment pipeline to rebuild from scratch

It short-circuits when every source file is already cached. To force a full
rebuild, clear the cache — the originals stay archived in the raw bucket, so
this is recoverable:

```bash
gcloud storage rm "gs://gcs-$PREFIX-enrollment-state-1/data_sources/**"
gcloud run jobs execute cr-$PREFIX-enrollment-1 --region=$REGION --project=$PROJECT --wait
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
  gcloud secrets versions add sm-$PREFIX-snowflake-password-1 --data-file=- --project=$PROJECT
```

The job reads `version = "latest"`, so the next run picks it up. Verify before
the next scheduled run:

```bash
gcloud run jobs execute cr-$PREFIX-lightcast-1 --region=$REGION --project=$PROJECT \
  --args="run,lightcast,--dataset,dim_area,--limit,10" --tasks=1 --wait
```

### Verify the IAM separation still holds

Phase 2's acceptance check, worth repeating after any IAM change:

```bash
# The enrollment SA must NOT be able to read the Snowflake secret.
gcloud secrets get-iam-policy sm-$PREFIX-snowflake-password-1 --project=$PROJECT \
  --format=json | grep -q "cr-$PREFIX-enrollment-1" \
  && echo "PROBLEM: enrollment can read the Snowflake secret" \
  || echo "OK: enrollment has no access to the Snowflake secret"

# PowerBI must be able to READ owc_marts...
bq show --format=prettyjson $PROJECT:owc_marts \
  | python3 -c 'import json,sys; a=json.load(sys.stdin)["access"]; \
      print("OK: PowerBI can read owc_marts" if any("powerbi" in str(e) and e.get("role")=="READER" for e in a) \
            else "PROBLEM: PowerBI cannot read owc_marts")'

# ...and must have NOTHING on staging (unvalidated) or ops (manifest, snapshots).
for ds in owc_staging owc_ops; do
  bq show --format=prettyjson $PROJECT:$ds | grep -q "sa-$PREFIX-powerbi-1" \
    && echo "PROBLEM: PowerBI has a grant on $ds" \
    || echo "OK: PowerBI has no grant on $ds"
done
```
