# Deployment

## How a change reaches production

```
PR -> dev   → ruff, mypy, derive-check, owcdata validate, unit tests
            → lock-check, terraform fmt / validate (dev + prod), tflint
            → terraform plan DEV, posted as a PR comment
      │
merge dev   → Cloud Build in the dev project, image tagged with the git SHA
            → terraform apply dev, with that digest
            → smoke run: lightcast --dataset dim_area --limit 1000, and enrollment
      │
PR dev -> prod  → same checks, but the plan posted is the PROD plan
      │
merge prod  → Cloud Build in the PROD project
            → terraform apply prod, with that digest
            → no smoke run (see below)
```

**Branch is the environment.** `dev` deploys to the dev project, `prod`
deploys to the prod project, and the two projects never touch each other.
Promotion is a pull request from `dev` into `prod`, so the thing being
promoted is a reviewable diff and the prod plan is attached to it.

`dev` is the default branch: GitHub bases new PRs on the default, so the safe
target is automatic and reaching production is a deliberate act of changing
the base.

### Why not build once and promote the digest

The obvious alternative is to build a single image and promote that exact
digest, which guarantees prod runs the bytes dev tested. It was the original
design here, and it was dropped for one reason: the only way to make it work
across two projects is for prod to pull its runtime image from **dev's**
Artifact Registry. That puts production's image inside the environment people
feel free to break, and it means anyone who can push to dev controls what
prod runs. Every other boundary in this repo is drawn to prevent exactly that.

Rebuilding per branch keeps the projects independent, at the cost of needing
the build to be reproducible — otherwise "same commit" would not mean "same
image". Two pins buy that back:

- `docker/Dockerfile` pins the base image by **digest**, not the
  `python:3.12-slim-bookworm` tag, which moves whenever upstream rebuilds.
- Dependencies install from a fully pinned `requirements.txt` (194
  transitive pins), not from `pyproject.toml`'s version ranges.

Those two lines are what make this model safe. `make lock-check` runs in CI
so the pins cannot silently drift from `pyproject.toml`, and
`make base-digest` reports when upstream has moved so refreshing the base is
a deliberate commit rather than something that happens to you.

This matters more than it looks. `xlrd` is the only reader for the pre-2019
`.xls` workbooks still linked on oklahoma.gov — losing or changing it in a
rebuild drops the oldest fiscal years *silently*, because the scrape still
succeeds with fewer years.

### The gate on production

Merging into `prod` is the gate, and it has teeth beyond repo settings:
`allowed_refs = ["refs/heads/prod"]` on the prod WIF provider means a token
minted from any other branch is rejected by **GCP**, not just by GitHub.

Required reviewers on the `prod` GitHub environment would add a second gate,
but that protection rule needs a paid plan on a private repo — GitHub returns
`422 Please ensure the billing plan supports the required reviewers
protection rule`. The trap is what happens when it cannot be created: the
environment still exists and the job still runs, gating nothing, silently. So
do not rely on it. Protect the `prod` branch instead — require a pull request
and at least one approval — which is free and is enforced before the workflow
ever starts.

## What dev does differently

The two environments run the same Terraform, and the roots are deliberately
near-identical so a change verified in dev reaches prod verbatim. `diff` them
and you should see exactly four differences:

| Setting | dev | prod | Why |
|---|---|---|---|
| `env_name` | `dev` | `prod` | Namespaces the log-based metrics and prints in alert titles. |
| `raw_bucket_force_destroy` | `true` | `false` | Lets `terraform destroy` clean up a scratch environment. Never true in prod. |
| `schedulers_paused` | `true` | `false` | **The important one.** Both read the same `pipelines.yml`, so without it dev fires prod's exact schedule — 41 Snowflake queries at 06:00 on the 1st, the same minute as prod, every month. Those credits bill to **Lightcast**, and both environments would contend for `TULSA_FOR_YOU_WH`. |
| `freshness_check_enabled` | `false` | `true` | Follows the line above. With schedulers paused, "has this run inside its interval?" is permanently no, so the alert would fire monthly for working-as-intended — on the same channel prod uses. |

Dev's schedulers are **created but paused**, not omitted. Terraform still
manages them, so the `oauth_token` wiring and the `run.invoker` grant are
exercised and drift-detected in dev rather than first tried in prod. To test
one, resume it by hand — but remember the next apply pauses it again unless
you flip the variable:

```bash
gcloud scheduler jobs resume cs-owc-dpar-d-lightcast-monthly-1 --location us-central1
```

So dev gets exercised by **deploys and by hand**, not by a cadence. The smoke
run in the deploy workflow is what proves the image works.

## Setting up GitHub Actions

**The workflows themselves need no creating** — `.github/workflows/ci.yml`
and `deploy.yml` are committed and run as soon as the repo has what they
need. That is nine repository variables and two environments.

Nothing here is required to deploy by hand; see
[Deploying by hand](#deploying-by-hand). Do it when you want Actions to
deploy for you.

### 1. Repository variables

**One command per environment**, which reads the values from that
environment's Terraform outputs:

```bash
make gh-vars ENV=dev
```

Run it again with `ENV=prod` **once prod has been applied** — not before. The
prod project has to exist and have state, or there is nothing to read.

`gh-vars` runs [`deployer-check`](03-gcp-setup.md#confirm-the-deployer-can-actually-deploy)
first, for the same reason `tf-apply` runs `preflight`. Setting these
variables is the moment deploys stop being yours and become CI's, so it is
the last moment the difference between your permissions and the deployer's
is cheap to find. Skipping straight to a push turns a one-second check into
a failed run and 23 identical 403s.

These are **variables, not secrets**: a WIF provider path and a service
account email are not sensitive, and there are no keys anywhere in this
setup.

> **Why a make target rather than `gh` one-liners.** `gh variable set --body
> "$(some-command)"` does **not** abort when the inner command fails — it
> passes an empty string, and `gh` then drops into an interactive
> `? Paste your variable` prompt. Press enter and you have set the variable
> to empty, which fails much later at the auth step with nothing pointing at
> the cause. `make gh-vars` resolves every value first and refuses to write
> if any is missing.

Verify what landed:

```bash
gh variable list
```

Nine in total: `REGION`, plus `PROJECT_ID_`, `NAME_PREFIX_`,
`WIF_PROVIDER_` and `DEPLOYER_SA_` for each of `DEV` and `PROD`. Until the
four `_PROD` ones exist, a push to `prod` stops at the "check prod is
configured" step and names exactly which are missing — expected, and it
affects nothing you deploy by hand.

### 2. Environments

**Settings → Environments.** Create two:

| Environment | Configure |
|---|---|
| `dev` | Nothing. It exists so the dev apply shows as a deployment. |
| `prod` | Nothing required. Add **required reviewers** if your plan supports it — a second gate, not the only one. |

```bash
gh api -X PUT "repos/{owner}/{repo}/environments/dev"
gh api -X PUT "repos/{owner}/{repo}/environments/prod"
```

The real gate is **branch protection on `prod`**, because it is enforced
before the workflow starts and it is free:

```bash
gh api -X PUT "repos/{owner}/{repo}/branches/prod/protection" \
  --input - <<'JSON'
{
  "required_pull_request_reviews": {"required_approving_review_count": 1},
  "required_status_checks": null,
  "enforce_admins": false,
  "restrictions": null
}
JSON
```

Backed by `allowed_refs = ["refs/heads/prod"]` in Terraform, so even a token
minted from another branch is refused by GCP.

### 3. Check the WIF condition allows the ref

Prod pins `allowed_refs = ["refs/heads/prod"]`, so only the `prod` branch can
deploy there. A branch or a fork's pull request cannot. Confirm what is
allowed:

```bash
make tf-output ENV=prod NAME=wif_attribute_condition
```

### 4. Verify

Open a pull request against `dev`. `ci.yml` should run lint, types, tests,
`lock-check`, `terraform validate` for both envs, and post the **dev** plan
as a PR comment. If the auth step fails, start at
[the runbook's WIF section](02-runbook.md#github-actions-deploys-fail-to-authenticate-via-wif).

Merging it runs `deploy.yml`: build in the dev project → apply dev → smoke
both pipelines.

Then open a pull request from `dev` into `prod`. The same checks run, but the
plan posted is the **prod** plan — review that, and merging deploys prod.

## The build identity

Builds run as `sa-<name_prefix>-build-1`, not as the Compute Engine default service
account. The default carries project **Editor**, and submitting a build
requires `actAs` on whatever identity it runs as — so using the default would
hand the deployer `actAs` on an Editor-privileged account.

That identity has three grants and nothing else: `logging.logWriter`
(required for a build with its own service account),
`storage.objectViewer` to read the uploaded source, and
`artifactregistry.writer` to push the image.

It is named through the `_BUILD_SA` substitution, which both `make build` and
the deploy workflow supply.

## Why the image is pinned by digest

The `pipeline` module's `image` variable validates that the reference contains
`@sha256:` and rejects a tag outright. A digest makes a rollback a revert; a
tag makes it a race against whatever is currently pushed under that tag.

## Deploying by hand {#deploying-by-hand}

```bash
make build ENV=dev              # builds, pushes, and prints the apply command

IMAGE=$(make -s image-digest ENV=dev)
make tf-init  ENV=dev
make tf-plan  ENV=dev TF_ARGS="-var=image_digest=$IMAGE"
make tf-apply ENV=dev TF_ARGS="-var=image_digest=$IMAGE"
```

`make build` prints the exact `-var=` line to copy. It also reads `project_id`
and `region` from the environment's `terraform.tfvars`, so the build lands in
the right project rather than gcloud's default.

The job's image is in `lifecycle.ignore_changes`, so it is set separately:

```bash
make set-image ENV=dev
make which-image ENV=dev     # confirm both jobs match the newest build
```

Or do the whole loop in one command:

```bash
make deploy ENV=dev          # build + push + point both jobs at it
```

**Why `ignore_changes` on the image:** during an incident someone will run
`gcloud run jobs update --image` to pin an older build. Without this, the next
unrelated `terraform apply` would silently revert that. The deploy workflow
sets the image explicitly for the same reason.

## Rolling back

### The application

Revert the commit on the branch and push. The branch is the environment, so
this is the whole procedure:

```bash
git checkout prod
git revert <commit>
git push
```

That rebuilds and redeploys the previous source. For an outage where a
rebuild is too slow, pin an older digest directly and revert afterwards:

```bash
gcloud run jobs update cr-<name_prefix>-lightcast-1 \
  --image <REGION>-docker.pkg.dev/<PROJECT>/ar-<name_prefix>-images-1/owcdata@sha256:OLDER \
  --region us-central1 --project <PROJECT>
```

The job's image is in `lifecycle.ignore_changes`, so the next unrelated
`terraform apply` will not revert that pin — but the next deploy of this
branch will, which is why the revert still needs to happen.

To find a previous digest:

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/owc-dpar-p/ar-owc-dpar-p-images-1/owcdata \
  --include-tags --sort-by=~CREATE_TIME --limit=10 --project $PROJECT
```

### A published table

Every run's Parquet stays in GCS under its own `run_id`, and
`owc_ops.pipeline_runs.source_uri` records the path. Rolling back reloads it:

```bash
owcdata rollback THE_TABLE                    # the run before the current one
owcdata rollback THE_TABLE --run-id RUN_ID    # a specific run
```

See [ADR-010](01-architecture.md#adr-010-rollback-from-the-gcs-parquet-not-a-bigquery-snapshot).

### Infrastructure

```bash
git revert <commit> && git push
```

The push to that branch re-applies. For something urgent, apply the reverted config
directly from a local checkout.

## Promoting dev → prod

Open a pull request from `dev` into `prod`:

```bash
gh pr create --base prod --head dev \
  --title "promote dev to prod" \
  --body "Deploying $(git rev-parse --short dev) to production."
```

CI posts the **prod** plan on that PR — that plan is the thing to review.
Merging it builds in the prod project and applies.

Before promoting, confirm dev is actually healthy rather than merely applied:

```bash
bq query --use_legacy_sql=false --project_id=$PROJECT \
'SELECT pipeline, dataset, status, row_count, finished_at
 FROM `owc_ops.pipeline_runs`
 WHERE started_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR)
 ORDER BY started_at DESC'
```

Then read the prod plan in the workflow log. Things worth stopping for:

- Any `destroy` on a bucket or a BigQuery dataset. `prevent_destroy` should
  refuse it, but a plan that even proposes one means something is wrong.
- A change to `wif_attribute_condition`. That is the line keeping other GitHub
  repositories out of the project.
- A change to `dataset_task_counts` you did not expect — it means `.sql` files
  were added or removed.

## Changing a schedule

Edit `pipelines.yml` and apply. Terraform reads that same file, so the
schedule in the repo and the schedule in GCP cannot drift:

```bash
$EDITOR pipelines.yml
make validate
make tf-plan ENV=dev
```

Filling in `quarterly.datasets` or `yearly.datasets` does three things in one
apply: it moves those datasets out of the monthly group, changes the monthly
task count, and creates the quarterly/yearly schedulers — which do not exist
while their lists are empty.

## Adding a dataset

Drop a `.sql` file in `sql/owc/` and apply. No config change:

```bash
cp new_thing.sql sql/owc/
make validate           # confirms it parses and is single-statement
make tf-plan ENV=dev    # task count goes 41 -> 42
```

## First deploy to a new project

See [`03-gcp-setup.md`](03-gcp-setup.md). The ordering matters — Artifact
Registry has to exist before `make build` can push to it.
