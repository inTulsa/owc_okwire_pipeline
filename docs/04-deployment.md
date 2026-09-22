# Deployment

## How a change reaches production

```
PR  → ruff, mypy, derive-check, owcdata validate, unit tests
    → terraform fmt / validate (dev + prod), tflint
    → terraform plan dev, posted as a PR comment
      │
main → Cloud Build, image tagged with the git SHA
    → terraform apply dev, with the digest
    → smoke run: lightcast --dataset dim_area --limit 1000, and enrollment
    → STOPS HERE
      │
prod → run the workflow by hand: Actions → Deploy → Run workflow
    → target: prod, image_digest: the digest already running in dev
    → terraform plan + apply prod
```

`dev` and `prod` are **environments, not branches**. There is no `dev` branch
in this model — `main` is the only branch that deploys, and promotion to prod
is a deliberate manual step.

One image is built and that **exact digest** is what you promote. Nothing is
rebuilt between dev and prod, so what was smoke-tested is what ships.

### Why prod is manual rather than an approval gate

The obvious design is required reviewers on the `prod` GitHub environment.
That protection rule needs a **paid plan on a private repo** — GitHub returns
`422 Please ensure the billing plan supports the required reviewers
protection rule`.

The trap is what happens when you cannot create it: **the environment still
exists and the job still runs.** It gates nothing, silently. So a push to
`main` would go straight to production.

Running the workflow by hand is the gate instead. It is explicit, it records
who did it, and it costs nothing. It also means the promotion and the
rollback are the same operation — both are "run Deploy with a digest".

To promote what dev is currently running:

```bash
IMAGE=$(make -s image-digest ENV=dev)
gh workflow run deploy.yml -f target=prod -f image_digest="$IMAGE"
```

**If you later upgrade the plan:** add required reviewers to the `prod`
environment and move `deploy-prod` back onto the push trigger by changing its
`if:` condition. Nothing else needs to change.

## Setting up GitHub Actions

**The workflows themselves need no creating** — `.github/workflows/ci.yml`
and `deploy.yml` are committed and run as soon as the repo has what they
need. That is seven repository variables and two environments.

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

Seven in total. Until the `_PROD` three exist, the prod deploy job fails at
its auth step — expected, and it affects nothing you deploy by hand.

### 2. Environments

**Settings → Environments.** Create two:

| Environment | Configure |
|---|---|
| `dev` | Nothing. It exists so the dev apply shows as a deployment. |
| `prod` | **Required reviewers** — add whoever approves production changes |

That reviewer prompt **is** the manual approval gate in the pipeline. There is
no workflow input for it and no way to skip it from the workflow file, which
is the point: the gate lives in repo settings where a workflow edit cannot
remove it silently.

```bash
gh api -X PUT "repos/{owner}/{repo}/environments/dev"
gh api -X PUT "repos/{owner}/{repo}/environments/prod" \
  -F "reviewers[][type]=User" -F "reviewers[][id]=$(gh api user -q .id)"
```

### 3. Check the WIF condition allows the ref

Prod pins `allowed_refs = ["refs/heads/main"]`, so only `main` can deploy
there. A branch or a fork's pull request cannot. Confirm what is allowed:

```bash
make tf-output ENV=prod NAME=wif_attribute_condition
```

### 4. Verify

Open a pull request. `ci.yml` should run lint, types, tests, `terraform
validate` for both envs, and post a dev plan as a PR comment. If the auth
step fails, start at
[the runbook's WIF section](02-runbook.md#github-actions-deploys-fail-to-authenticate-via-wif).

Merging to `main` then runs `deploy.yml`: build → apply dev → smoke both
pipelines → **wait for approval** → apply prod.

## The build identity

Builds run as `okw-build-<env>`, not as the Compute Engine default service
account. The default carries project **Editor**, and submitting a build
requires `actAs` on whatever identity it runs as — so using the default would
hand the deployer `actAs` on an Editor-privileged account.

`okw-build-<env>` has three grants and nothing else: `logging.logWriter`
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

Re-run the deploy workflow with an older digest — no rebuild, no revert
needed:

```bash
gh workflow run deploy.yml \
  -f image_digest=us-central1-docker.pkg.dev/owc-data-prod/okw-images/owcdata@sha256:OLDER
```

Or immediately, without waiting for CI:

```bash
gcloud run jobs update okw-lightcast-prod \
  --image us-central1-docker.pkg.dev/owc-data-prod/okw-images/owcdata@sha256:OLDER \
  --region us-central1 --project owc-data-prod
```

To find a previous digest:

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/owc-data-prod/okw-images/owcdata \
  --include-tags --sort-by=~CREATE_TIME --limit=10 --project owc-data-prod
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

The `main` push re-applies. For something urgent, apply the reverted config
directly from a local checkout.

## Promoting dev → prod

```bash
IMAGE=$(make -s image-digest ENV=dev)
gh workflow run deploy.yml -f target=prod -f image_digest="$IMAGE"
```

Passing dev's digest is what makes this a *promotion* rather than a fresh
build: the artifact that ships is the one dev smoke-tested. Omitting it
builds from the current commit instead, which is occasionally what you want
and usually not.

Before promoting, confirm dev is actually healthy rather than merely applied:

```bash
bq query --use_legacy_sql=false --project_id=owc-data-dev \
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
