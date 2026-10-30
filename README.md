# OWC Data Platform

Two production data pipelines, one schedule, one warehouse, one runbook.

| | **lightcast** | **enrollment** |
|---|---|---|
| Source | Snowflake data share (Lightcast reader account) | `oklahoma.gov` public webpage (scraped) |
| Extract | 35 independent SQL files | HTML parse → Excel download → reshape |
| State | Stateless; re-queries every run | Stateful; caches downloads, short-circuits when nothing is new |
| Cadence | Monthly / quarterly / yearly by dataset | Checked monthly; data lands ~annually by fiscal year |

Both land in BigQuery (`owc_marts`), which PowerBI reads directly. Schedules
live in [`pipelines.yml`](pipelines.yml).

> **`owc-dpar-d` is live. `owc-dpar-p` has not been built.** Dev runs both
> pipelines end to end on the deploy-identity model — deploys run as
> `sa-<prefix>-deploy-1`, impersonated, and no human needs an admin role to
> deploy. Prod is built by following [`deploy.md`](docs/deploy.md), after
> the eleven roles the deploy account needs are
> [agreed with the platform team](docs/OPEN-ITEMS.md#prod-role-set).
>
> Building prod is also the first real test of these documents. Keep notes,
> and fix the document wherever a step needed improvising —
> [handoff status](docs/OPEN-ITEMS.md#delivery-status).

## Start here

**Standing an environment up, or deploying a change?**
→ **[`docs/deploy.md`](docs/deploy.md)**. That is the whole procedure, nine
steps, and it is the only one. Everything else below is reference.

From Google Cloud Shell:

```bash
# 1. get the code
cd ~ && git clone https://github.com/Oklahoma-Workforce-Commission-840/OK-wire-data-pipeline.git owc && cd owc

# 2. Cloud Shell logs gcloud in for you, but NOT Terraform.
#    First: no IPv6 route means gcloud works and every terraform call
#    fails. Ten seconds now saves an hour. See deploy.md#ipv6-preflight.
curl -s -m 5 -6 https://storage.googleapis.com >/dev/null || echo "NO IPv6 — open a new Cloud Shell session before continuing"

#    Then ORDER MATTERS: authenticate as yourself BEFORE taking on the
#    deploy identity. Reversed, the login writes the impersonation into
#    the ADC file and the only fix is starting over. deploy.md#adc-ordering
gcloud auth application-default login
gcloud config set project owc-dpar-d
gcloud auth application-default set-quota-project owc-dpar-d
eval "$(make -s env-exports ENV=dev)"

# 3. Cloud Shell ships a terraform stub, not terraform
make install-terraform
make doctor                     # must end "Ready."

# 4. what am I allowed to do here? read-only, needs no rights
make access-check ENV=dev

# 5. the ONE step needing admin rights, once per project.
#    Not an admin? Hand your project admin a standalone script instead —
#    no repo and no roles granted to you:
#       make omes-script ENV=dev > owc-setup.sh
make gcloud-admin ENV=dev

# 6. publish the code, confirm step 5 landed
make source-push ENV=dev
make iam-check   ENV=dev

# 7. stand it up. stops once for the Snowflake password, then run it again
make up ENV=dev

# 8. one real run of each pipeline
make smoke ENV=dev

# 9. give PowerBI its key. needs an admin's grant first: deploy.md#connect-powerbi
make powerbi-key ENV=dev
```

Step 5 is the one that needs elevated rights, and the one someone else may
have to run. `make access-check` tells you which of those you are. Step 9
also needs an admin, once: the deploy account cannot create the PowerBI key
until it is granted key-admin on that one account.

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
| Who can do what, and how is that proven? *(for a security review)* | [`security-model.md`](docs/security-model.md) |
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
sql/owc/          35 .sql files, verbatim from owcpipelines
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
