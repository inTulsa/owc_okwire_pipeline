# Deployment

## How a change reaches production

```
PR  → ruff, mypy, derive-check, owcdata validate, 128 unit tests
    → terraform fmt / validate (dev + prod), tflint
    → terraform plan dev, posted as a PR comment
      │
main → Cloud Build, image tagged with the git SHA
    → terraform apply dev, with the digest
    → smoke run: lightcast --dataset dim_area --limit 1000, and enrollment
    → ⏸  MANUAL APPROVAL  (GitHub environment `prod`, required reviewers)
    → terraform plan + apply prod, same digest
```

One image is built and that **exact digest** is deployed to both environments.
Nothing is rebuilt between dev and prod, so what was smoke-tested is what
ships.

## Why the image is pinned by digest

The `pipeline` module's `image` variable validates that the reference contains
`@sha256:` and rejects a tag outright. A digest makes a rollback a revert; a
tag makes it a race against whatever is currently pushed under that tag.

## Deploying by hand

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

Every publish snapshots the marts table first. Snapshots are near-free — they
bill only for bytes that later diverge.

```bash
bq ls --project_id=owc-data-prod owc_ops | grep THE_TABLE
.venv/bin/owcdata rollback THE_TABLE owc-data-prod.owc_ops.THE_TABLE__RUN_ID
```

### Infrastructure

```bash
git revert <commit> && git push
```

The `main` push re-applies. For something urgent, apply the reverted config
directly from a local checkout.

## Promoting dev → prod

The approval gate on the `prod` GitHub environment is the whole mechanism —
there is no separate promotion step, because the same digest is already what
dev is running.

Before approving, confirm dev is actually healthy rather than merely applied:

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
