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

## Quick start

**Deploying or operating an environment** — from Google Cloud Shell, which
needs nothing installed:

```bash
# 1. get the code (or upload a tarball — see the doc)
cd ~ && git clone https://github.com/inTulsa/owc_okwire_pipeline.git owc && cd owc

# 2. Cloud Shell logs gcloud in for you, but NOT Terraform
eval "$(make -s env-exports ENV=dev)"
gcloud auth application-default login
gcloud auth application-default set-quota-project $PROJECT

make doctor                     # 3. green light before anything is created

make gcloud-admin ENV=dev       # 4. ONE TIME, privileged: identities + project IAM
make source-push  ENV=dev       #    mirror the repo into the project
make iam-check    ENV=dev       #    prove it landed

make up    ENV=dev              # 5. stops once for the Snowflake password,
                                #    then run it again
make smoke ENV=dev              # 6. one real run of each pipeline
```

Terraform holds no `projectIamAdmin` and no `serviceAccountAdmin`, and there
is no GitHub in the path. **[`docs/09-gcloud-deploy.md`](docs/09-gcloud-deploy.md)
is the only deploy procedure** — what each step does, and why it is split that
way.

**Changing the code** — needs a Python toolchain, so a workstation or a
Cloud Shell with `make setup` run:

```bash
make setup
cp .env.example .env            # fill in SNOWFLAKE_USER / SNOWFLAKE_PASSWORD
make validate                   # config + SQL parse, no network
make run PIPELINE=lightcast DATASET=dim_area LIMIT=1000
make run PIPELINE=enrollment TARGET=local
```

`make help` lists every target. Full walkthrough:
[`docs/05-local-development.md`](docs/05-local-development.md).

## Documentation

| Doc | Audience |
|---|---|
| [`00-overview.md`](docs/00-overview.md) | **Non-technical** — what each pipeline produces, how fresh it is, what an alert email means |
| [`01-architecture.md`](docs/01-architecture.md) | Data flow and the ADRs behind it |
| [`02-runbook.md`](docs/02-runbook.md) | **On-call** — one entry per alert: symptom → diagnosis → fix |
| [`03-gcp-setup.md`](docs/03-gcp-setup.md) | Why each resource is shaped the way it is. For the OMES projects, deploy from **09** instead. |
| [`04-deployment.md`](docs/04-deployment.md) | GitHub Actions setup, deploy, roll back, promote dev → prod. **Not the current path** — see 09. |
| [`05-local-development.md`](docs/05-local-development.md) | Running the pipelines and changing the code |
| [`06-adding-a-pipeline.md`](docs/06-adding-a-pipeline.md) | Adding a dataset vs. adding a whole pipeline |
| [`07-monitoring.md`](docs/07-monitoring.md) | Every alert, its threshold, and why |
| [`08-developer-setup.md`](docs/08-developer-setup.md) | **Start here** — Cloud Shell vs a workstation, what each needs, access to request |
| [`09-gcloud-deploy.md`](docs/09-gcloud-deploy.md) | **The OMES path** — deploy from gcloud, with Terraform holding no IAM permissions |
| [`OPEN-ITEMS.md`](docs/OPEN-ITEMS.md) | **Decisions still needing a human** — read this before go-live |

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
infra/terraform/  platform + a reusable `pipeline` module, instantiated twice
infra/gcloud/     the one-time privileged setup, in plain gcloud — identities,
                  project IAM, API enables, state and source buckets
```

## Repository provenance

- `sql/owc/` is byte-identical to `owcpipelines`. No query was rewritten.
- `src/owcdata/pipelines/enrollment/scrape.py` is the 759-line
  `primary_enrollment_data_script.py` with its parsing, reshaping, and caching
  behavior intact — see the header comment in that file for the exact list of
  changes, all of which are about reporting failure rather than about parsing.
