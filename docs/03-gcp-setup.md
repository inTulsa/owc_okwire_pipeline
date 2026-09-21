# GCP setup

One-time bootstrap per environment. About 30 minutes.

## What you need first

- A GCP project with billing linked, one per environment
  (`owc-data-dev`, `owc-data-prod`)
- `roles/owner` on it, or enough to create service accounts and set IAM
- `gcloud` and `terraform` locally
- The Snowflake reader-account password
- A distribution list for alerts — **not** an individual's address, so people
  can join and leave without a Terraform change

## 1. Bootstrap the two things Terraform cannot create

```bash
./infra/bootstrap/bootstrap.sh owc-data-dev
```

This enables `cloudresourcemanager.googleapis.com` and
`serviceusage.googleapis.com`, and creates `gs://okw-tfstate`.

**Why by hand:** `google_project_service` needs Service Usage to make the API
call and Cloud Resource Manager to resolve the project, so Terraform cannot
enable the APIs that let it enable APIs. And Terraform cannot create the
bucket that holds its own state. Everything else — the other 13 APIs and every
resource — is Terraform's job.

## 2. Fill in tfvars

```bash
$EDITOR infra/terraform/envs/dev/terraform.tfvars
```

| Variable | Notes |
|---|---|
| `project_id` | This environment's project |
| `github_repository` | `owner/repo`, exactly. **Validated — no wildcards.** See step 5. |
| `allowed_refs` | `[]` for dev; `["refs/heads/main"]` for prod |
| `alert_emails` | The distribution list |
| `snowflake_user` | The login. Not a secret; the password goes to Secret Manager. |
| `billing_account` | Only needed if you want the budget alert |

## 3. Build an image

Terraform **requires a digest**, not a tag, and has no default — a forgotten
image should be a plan error, not a job that cannot pull at 06:00.

```bash
make build ENV=dev
```

Then get the digest:

```bash
gcloud artifacts docker images describe \
  us-central1-docker.pkg.dev/owc-data-dev/okw-images/owcdata:$(git rev-parse --short HEAD) \
  --format='value(image_summary.digest)' --project owc-data-dev
```

> **Ordering note.** `make build` pushes to Artifact Registry, which Terraform
> creates. On a brand-new project, run step 4 once with
> `-target=module.platform` to create the registry, then build, then do the
> full apply:
>
> ```bash
> cd infra/terraform/envs/dev
> terraform init
> terraform apply -target=module.platform \
>   -var='image_digest=placeholder@sha256:0000000000000000000000000000000000000000000000000000000000000000'
> ```

## 4. Apply

```bash
make tf-init ENV=dev
cd infra/terraform/envs/dev
terraform apply -var="image_digest=us-central1-docker.pkg.dev/owc-data-dev/okw-images/owcdata@sha256:THEDIGEST"
```

Then store the Snowflake password. The secret container is created by
Terraform; **the value is never in Terraform state**:

```bash
printf '%s' 'THE_PASSWORD' | \
  gcloud secrets versions add okw-snowflake-password-dev --data-file=- --project owc-data-dev
```

**Verify the apply is idempotent** — a second apply must show no changes:

```bash
terraform apply
# Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
```

## 5. The WIF attribute condition — read this one

The Workload Identity Federation provider carries an `attribute_condition`
restricting `assertion.repository`:

```bash
terraform output wif_attribute_condition
# assertion.repository == "tulsateam/owc_okwire_pipeline"
```

**Without it, any GitHub repository on earth can mint tokens for this
project.** It is the most common WIF misconfiguration and a full compromise.
The module's variable validation refuses an empty or wildcard value, and this
output exists specifically so the condition is visible in every plan diff.

For prod, also set `allowed_refs = ["refs/heads/main"]`. That stops a branch —
or a fork's pull request — from deploying.

Wire the outputs into GitHub as **repository variables**:

```bash
terraform output workload_identity_provider   # -> WIF_PROVIDER_DEV
terraform output deployer_service_account     # -> DEPLOYER_SA_DEV
```

Plus `PROJECT_ID_DEV`, `PROJECT_ID_PROD`, `REGION`, and the `_PROD` variants.

## 6. Verify the identity separation

Each pipeline has its own service account, and every grant is scoped to a
specific resource. Confirm the separation is real:

```bash
ENV=dev PROJECT=owc-data-dev

# The enrollment SA must NOT be able to read the Snowflake secret.
gcloud secrets get-iam-policy okw-snowflake-password-$ENV --project=$PROJECT --format=json \
  | grep -q "okw-enrollment-$ENV" \
  && echo "PROBLEM: enrollment can read the Snowflake secret" \
  || echo "OK: enrollment has no secret access"

# The lightcast SA must NOT be able to write the scrape cache.
gcloud storage buckets get-iam-policy gs://okw-enrollment-state-$ENV --format=json \
  | grep -q "okw-lightcast-$ENV" \
  && echo "PROBLEM: lightcast can write the scrape cache" \
  || echo "OK: lightcast has no access to the enrollment state bucket"
```

## 7. Region co-location

`location` feeds both the GCS buckets and all four BigQuery datasets from one
variable. **This is mandatory, not a preference:** a load job from a bucket in
one location into a dataset in another fails outright. Never set them
separately, and never mix them between environments you plan to copy data
between.

## 8. Smoke test

```bash
cd infra/terraform/envs/dev

gcloud run jobs execute $(terraform output -raw lightcast_job) \
  --region us-central1 --project owc-data-dev \
  --args="run,lightcast,--dataset,dim_area,--limit,1000" --tasks=1 --wait

gcloud run jobs execute $(terraform output -raw enrollment_job) \
  --region us-central1 --project owc-data-dev --wait
```

Then confirm the manifest recorded both:

```bash
bq query --use_legacy_sql=false --project_id=owc-data-dev \
'SELECT pipeline, dataset, status, row_count FROM `owc_ops.pipeline_runs` ORDER BY started_at DESC LIMIT 10'
```

## Terraform guardrails

`prevent_destroy` is set on the raw bucket, the enrollment state bucket, and
`owc_marts`. In prod, `raw_bucket_force_destroy = false` as well. Prod applies
go through a GitHub environment with required reviewers.

The realistic disaster for a small team is a fat-fingered `terraform destroy`,
not a quota.

## Repeat for prod

Same steps with `ENV=prod`, plus:

- `allowed_refs = ["refs/heads/main"]`
- Configure **required reviewers** on the `prod` GitHub environment. That
  approval gate is the manual step in the deploy pipeline.
- Leave `raw_bucket_force_destroy = false`.
