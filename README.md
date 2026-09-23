# OWC Data Platform

Two production data pipelines, one schedule, one warehouse, one runbook.

| | **lightcast** | **enrollment** |
|---|---|---|
| Source | Snowflake data share (Lightcast reader account) | `oklahoma.gov` public webpage (scraped) |
| Extract | 41 independent SQL files | HTML parse → Excel download → reshape |
| State | Stateless; re-queries every run | Stateful; caches downloads, short-circuits when nothing is new |
| Cadence | Monthly / quarterly / yearly by dataset | Checked monthly; data lands ~annually by fiscal year |

Both land in BigQuery (`owc_marts`), which PowerBI reads directly. Schedules
live in [`pipelines.yml`](pipelines.yml).

## Start here

**Standing an environment up, or deploying a change?**
→ **[`docs/deploy.md`](docs/deploy.md)**. That is the whole procedure, six
steps, and it is the only one. Everything else below is reference.

From Google Cloud Shell:

```bash
# 1. get the code
cd ~ && git clone https://github.com/inTulsa/owc_okwire_pipeline.git owc && cd owc

# 2. Cloud Shell logs gcloud in for you, but NOT Terraform
eval "$(make -s env-exports ENV=dev)"
gcloud auth application-default login
gcloud auth application-default set-quota-project $PROJECT

# 3. Cloud Shell ships a terraform stub, not terraform
make install-terraform
make doctor                     # must end "Ready."

# 4. what am I allowed to do here? read-only, needs no rights
make access-check ENV=dev

# 5. the ONE step needing admin rights, once per project.
#    Not an admin on this project? Send the request instead:
#       make omes-request ENV=dev > owc-setup-request.txt
make gcloud-admin ENV=dev

# 6. publish the code, confirm step 5 landed
make source-push ENV=dev
make iam-check   ENV=dev

# 7. stand it up. stops once for the Snowflake password, then run it again
make up ENV=dev

# 8. one real run of each pipeline
make smoke ENV=dev
```

Step 5 is the only one that needs elevated rights, and the only one someone
else may have to run. `make access-check` tells you which of those you are.

Add `PROJECT=your-project` to every command to aim the same process at a
different project. Nothing is edited and nothing has to be changed back.

## Documentation

Named for the question they answer, not numbered — read the one you need.

| When | Doc |
|---|---|
| **I want to deploy, or change what is deployed** | [`deploy.md`](docs/deploy.md) |
| **An alert fired / something is broken** | [`runbook.md`](docs/runbook.md) |
| What does this system actually produce? *(non-technical)* | [`overview.md`](docs/overview.md) |
| How does it work, and why is it built this way? | [`architecture.md`](docs/architecture.md) |
| What did the deploy create, and why is that bucket configured like that? | [`gcp-reference.md`](docs/gcp-reference.md) |
| I want to run a pipeline or change the code | [`local-development.md`](docs/local-development.md) |
| I want to add a dataset or a new pipeline | [`adding-a-pipeline.md`](docs/adding-a-pipeline.md) |
| What are the alerts and why does each exist? | [`monitoring.md`](docs/monitoring.md) |
| What still needs a human decision? **Read before go-live** | [`OPEN-ITEMS.md`](docs/OPEN-ITEMS.md) |

The enrollment pipeline's original business-process documentation is preserved
verbatim in [`docs/enrollment/`](docs/enrollment/).

## Layout

```
src/owcdata/
  cli.py          owcdata run <pipeline> [--dataset] [--limit] [--target]
  config.py       env + pipelines.yml, validated at startup
  core/           sinks, publish, quality, run manifest — shared by both pipelines
  pipelines/
    lightcast/    Snowflake → Arrow → Parquet, one dataset per Cloud Run task
    enrollment/   the original scraper, parsing logic unchanged
sql/owc/          41 .sql files, verbatim from owcpipelines
infra/terraform/  platform + a reusable `pipeline` module, instantiated twice.
                  Creates resources only: no service accounts, no project IAM.
infra/gcloud/     the one-time privileged setup, in plain gcloud — identities,
                  project IAM, API enables, state and source buckets
```

## Testing against another project

Same files, same commands, one variable:

```bash
make gcloud-admin ENV=dev PROJECT=my-test-project
make up           ENV=dev PROJECT=my-test-project
```

`PROJECT` feeds the gcloud steps, the terraform variables, and the state
bucket at `init`, so nothing is edited and nothing has to be changed back.

## Repository provenance

- `sql/owc/` is byte-identical to `owcpipelines`. No query was rewritten.
- `src/owcdata/pipelines/enrollment/scrape.py` is the 759-line
  `primary_enrollment_data_script.py` with its parsing, reshaping, and caching
  behavior intact — see the header comment in that file for the exact list of
  changes, all of which are about reporting failure rather than about parsing.
