# Adding a dataset, or a whole pipeline

## Adding a Lightcast dataset

Drop the file in and apply:

```bash
cp my_query.sql sql/owc/
make validate
make tf-plan ENV=dev
```

That is the entire procedure. Unlisted `.sql` files fall into
`defaults.group`, which preserves the original pipeline's
glob-the-directory behavior, and Terraform derives the Cloud Run task count
from the files on disk — so the count goes from 41 to 42 with no config edit.

Requirements on the file:

- **Single statement.** `owcdata validate` checks this, comment-aware. A
  trailing semicolon is fine; a semicolon with SQL after it is not, because
  `--limit` wraps the query in a subquery.
- **Name it what you want the BigQuery table called.** `my_query.sql` →
  `owc_staging.my_query` → `owc_marts.my_query` → a view at
  `owc_marts.my_query`, which is what PowerBI reads.

Optionally add quality checks in `pipelines.yml`:

```yaml
lightcast:
  quality:
    known_row_counts:
      my_query: 1234          # an exact count you already know is true
    not_null:
      my_query: [AREAID]      # columns that must never be null
```

To put it on a different cadence, name it under a group. A dataset named in
two groups is a config error — it would be extracted twice per cycle and
billed to Lightcast twice.

## Adding a whole pipeline

The `pipeline` module is the contract. It is instantiated twice today, and
those two are about as different as two pipelines get:

| | lightcast | enrollment |
|---|---|---|
| tasks | one per dataset (41) | 1 |
| parallelism | 4 | 1 |
| timeout | 2h | 30m |
| secrets | the Snowflake password | **none** |
| state | stateless | GCS volume mount |
| schedules | up to 3 | 1 |
| alerts | quality, drift, extract | no-files, reshape-skipped, quality |

If a third pipeline fits that shape, it is a module block and a tfvars entry.

### 1. Python

```
src/owcdata/pipelines/<name>/
├── __init__.py
└── run.py          # def run(settings, config, *, bq=None, manifest=None) -> ...
```

`run.py` must:

- **Raise on failure.** Anything from `owcdata.errors`. The CLI turns the
  exception into an exit code, and every alert depends on that exit code. This
  is the one non-negotiable requirement.
- Write a `RunRecord` per dataset via `ManifestWriter`. The freshness alert
  and the quality gate's prior-run baseline both read
  `owc_ops.pipeline_runs`; a pipeline that does not write there is invisible
  to alert 2.
- Use `build_sink(settings, "<name>")` for output, which gives it its own GCS
  prefix and therefore its own IAM scope.
- Call `land_parquet` or `land_dataframe` from `core/publish.py` to load,
  validate, and publish. Do not reimplement that path.

### 2. Config

```yaml
# pipelines.yml
my_pipeline:
  schedule: "0 8 1 * *"
  table: my_table
  freshness_grace_hours: 48
  quality:
    not_null:
      my_table: [some_column]
```

Add a matching model to `config.py` and a field on `PipelinesConfig`, so a bad
config fails at startup rather than mid-run.

### 3. CLI

Add a branch in `cli.py`:

```python
elif pipeline == "my_pipeline":
    from owcdata.pipelines.my_pipeline import run as my_pipeline
    my_pipeline.run(settings, config, bq=bq)
```

### 4. Platform

A service account and its scoped grants, in
`infra/terraform/modules/platform/iam.tf`. Add the name to
`local.pipeline_sa_emails` and the dataset/logging/metric grants follow
automatically. Give it a secret only if it genuinely needs one — the point of
per-pipeline identities is that the scraper cannot read the Snowflake password
and the Lightcast job cannot write the scrape cache.

### 5. The module block

```hcl
module "my_pipeline" {
  source = "../../modules/pipeline"

  name       = "my_pipeline"
  project_id = var.project_id
  env        = var.env_name
  region     = var.region
  image      = var.image_digest
  labels     = local.labels

  service_account_email           = module.platform.service_account_emails.my_pipeline
  scheduler_service_account_email = module.platform.service_account_emails.scheduler

  schedules = [{
    name       = "monthly"
    cron       = local.pipelines.my_pipeline.schedule
    args       = []
    task_count = 1
  }]

  task_timeout = "1800s"   # explicit: the default is 10 MINUTES
  parallelism  = 1
  memory       = "2Gi"

  env_vars              = local.common_env
  notification_channels = module.platform.notification_channels

  event_alerts = [{
    key         = "alert-my-thing"
    event       = "my_event_name"   # must match a jsonPayload.event the code emits
    title       = "ALERT: my pipeline hit the thing"
    description = "What it means and what to do about it."
  }]
}
```

Add the pipeline to `freshness_thresholds` in the `module "platform"` block,
or alert 2 will never fire for it.

### 6. Tests

At minimum: a fixture test of whatever the source shape is, and an exit-code
test proving failure is non-zero. For a scraper, save real HTML as a fixture —
those are the highest-value tests in this repo.

## Things that catch people out

**`task_timeout` has no default here on purpose.** Cloud Run's own default is
10 minutes and would silently kill a long query.

**Memory and CPU are coupled.** 1 vCPU allows 512 MiB–4 GiB. Asking for 32 GiB
forces 8 vCPU nobody needs.

**Cloud Run's filesystem is in-memory in both execution generations, with no
size limit.** Writing past the memory allocation crashes the instance. Stream
to the sink; do not stage on local disk.

**A GCS volume mount requires gen2** (set by the module) **and must complete
within 30 seconds** or the job fails.

**Event strings are duplicated between the code and Terraform.** A typo'd
`event` applies cleanly and then never fires, which is worse than no alert.
`tests/unit/test_exit_codes.py` pins the existing ones; add yours there.
