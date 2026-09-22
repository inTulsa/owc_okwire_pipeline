# GCP setup

One-time bootstrap per environment. About 30 minutes.

## What you need first

- A GCP project with billing linked, one per environment
  (`owc-dpar-d`, `owc-dpar-p`)
- `roles/owner` on it, or enough to create service accounts and set IAM
- `gcloud` and `terraform` locally
- The Snowflake reader-account password
- A distribution list for alerts — **not** an individual's address, so people
  can join and leave without a Terraform change

### Authenticate twice

gcloud and Terraform use **different** credentials, and having one without the
other is the most common way this setup fails on a fresh machine:

```bash
gcloud auth login                                    # the gcloud CLI itself
gcloud auth application-default login                # what TERRAFORM uses
gcloud config set project owc-dpar-d
gcloud auth application-default set-quota-project owc-dpar-d
```

The quota project matters more than it looks. Terraform's GCS backend bills
every call to whatever `quota_project_id` sits in your Application Default
Credentials; if that project is deleted or inactive, **every** call returns
`404 The requested project was not found`, which Terraform reports as
`storage: bucket doesn't exist` — pointing at the wrong thing entirely.
`bootstrap.sh` checks for this in step 1 and tells you the fix. Diagnosis is in
[the runbook](02-runbook.md#first-deploy-failures).

## 1. Bootstrap the two things Terraform cannot create

```bash
./infra/bootstrap/bootstrap.sh owc-dpar-d
```

This enables `cloudresourcemanager.googleapis.com` and
`serviceusage.googleapis.com`, creates `gs://gcs-owc-dpar-d-tfstate-1`, and then **verifies
that Terraform's own credentials can read that bucket** — running the exact
`objects.list` call the GCS backend makes, including the quota-project header.
If it cannot, the script stops with the specific fix rather than letting
`terraform init` fail with a misleading message.

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
| `github_repository` | `owner/repo`, exactly. **Validated — no wildcards.** See step 6. |
| `allowed_refs` | `[]` for dev (CI plans PRs as the dev deployer, from arbitrary refs); `["refs/heads/prod"]` for prod |
| `alert_emails` | The distribution list |
| `snowflake_user` | The login. Not a secret; the password goes to Secret Manager. |
| `billing_account` | Only needed if you want the budget alert. Off by default in both envs (`billing_budget_amount = 0`) — see below before turning it on. |

> **Turning the budget alert on costs one manual grant.** A
> `google_billing_budget` lives on the **billing account**, not the project,
> so Terraform cannot grant the deployer access to it the way it grants
> everything else here. Set an amount and a `billing_account`, then also:
>
> ```bash
> gcloud billing accounts add-iam-policy-binding <ACCOUNT_ID> \
>   --member=serviceAccount:sa-<name_prefix>-deployer-1@<project>.iam.gserviceaccount.com \
>   --role=roles/billing.costsManager
> ```
>
> Without it, hand applies keep working and **CI 403s on every refresh of the
> budget** — the same shape of failure as
> [the deployer permission gap](#confirm-the-deployer-can-actually-deploy),
> and `deployer-check` will not catch it because the role is not project-level.

## 3. Create Artifact Registry and the secret container

**Do this before `make build`.** Terraform creates the Artifact Registry
repository that `make build` pushes to, so on a brand-new project the build
has nowhere to push and fails with:

```
name unknown: Repository "ar-$PREFIX-images-1" not found
```

```bash
make tf-bootstrap ENV=dev
```

This targets exactly two resources — the Artifact Registry repository and the
Snowflake secret container — plus the API enablement they depend on. Nothing
else. Keeping the target this narrow is deliberate: an earlier version applied
the whole platform module and failed on unrelated monitoring resources even
though the registry itself was created fine. A bootstrap step should have the
smallest blast radius that unblocks the next step.

Those two exist because each unblocks something later: the registry is what
`make build` pushes to, and the secret container is what you store the password
into — which has to happen **before** the apply in step 5.

Enabling the APIs here also gets Cloud Build's service agent provisioned well
before step 4, which is what otherwise causes a `PERMISSION_DENIED` on the
first submit.

It supplies a placeholder digest itself, so you never type one. That
placeholder exists only to satisfy the pipeline module's "must be pinned by
digest" validation, which Terraform evaluates even for resources `-target`
excludes. **No Cloud Run job is created by this step.**

### Store the Snowflake password now

Do this **before** step 5, not after. The lightcast Cloud Run job mounts
`SNOWFLAKE_PASSWORD` from `sm-owc-dpar-d-snowflake-password-1/versions/latest`, and
`latest` cannot resolve to nothing — with no version, job creation fails with:

```
Secret projects/.../secrets/sm-owc-dpar-d-snowflake-password-1/versions/latest was not found
```

Terraform creates the container but never the value, deliberately, so the
password stays out of Terraform state:

```bash
printf '%s' 'THE_PASSWORD' | \
  gcloud secrets versions add sm-owc-dpar-d-snowflake-password-1 --data-file=- --project owc-dpar-d
```

`make tf-apply` preflights this and refuses to start if the version is
missing, so a forgotten password costs a second rather than failing several
minutes into an apply.

## 4. Build an image

Terraform **requires a digest**, not a tag, and has no default — a forgotten
image should be a plan error, not a job that cannot pull at 06:00.

```bash
make build ENV=dev
```

`make build` reads `project_id` and `region` from that environment's
`terraform.tfvars`, tags the image with the current git short SHA, and prints
the digest-pinned reference at the end — so `make build ENV=prod` cannot
quietly build into the dev project. To re-print the digest for an image you
already built:

```bash
make image-digest ENV=dev
```

> **If the build fails with `PERMISSION_DENIED` even though you are project
> owner:** enabling `cloudbuild.googleapis.com` provisions the Cloud Build
> service agent asynchronously, and submits are rejected until it lands.
> Wait ~30 seconds and re-run. Doing step 3 first usually avoids this
> entirely, because Terraform enables the API well before you build.

## 5. Complete the apply

Now that a real image exists, apply everything — this is what creates the
Cloud Run jobs and the schedulers:

`make image-digest` prints the reference and nothing else, so it composes:

```bash
IMAGE=$(make -s image-digest ENV=dev)
echo "$IMAGE"   # us-central1-docker.pkg.dev/owc-dpar-d/ar-$PREFIX-images-1/owcdata@sha256:...

make tf-apply ENV=dev TF_ARGS="-var=image_digest=$IMAGE"
```

**Verify the apply is idempotent** — a second apply must show no changes:

```bash
make tf-apply ENV=dev TF_ARGS="-var=image_digest=$IMAGE"
# Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
```

## 6. The WIF attribute condition — read this one

> **This step is only for CI.** Workload Identity Federation exists so
> **GitHub Actions** can deploy without a JSON key. Deploying by hand — every
> `make tf-apply` you have run so far — uses *your own* gcloud credentials and
> never touches WIF.
>
> So you can skip ahead to step 7 and finish with a fully working dev
> environment. Come back when you want Actions to deploy. Nothing between
> `make wif-check` and the GitHub variables needs doing.

The Workload Identity Federation provider carries an `attribute_condition`
restricting `assertion.repository`:

```bash
make tf-output ENV=dev NAME=wif_attribute_condition
```

It should print exactly:

```text
assertion.repository == "inTulsa/owc_okwire_pipeline"
```

> `make tf-output` exists because every other Terraform step here cds into the
> env directory for you. A bare `terraform output` from the repo root reports
> **"No outputs found"**, which reads like the outputs are missing rather than
> like you are in the wrong directory.

### The casing is load-bearing

GitHub's `assertion.repository` claim preserves the **exact casing** of the
owner and repository, and the CEL comparison is case-sensitive. So
`intulsa/...` does not match `inTulsa/...`.

A mismatch fails **closed** — deploys simply stop authenticating — so it is
safe but silent, and easy to lose an afternoon to. `make preflight` (which
`make tf-apply` runs) compares `github_repository` against your actual git
remote and refuses to apply on a mismatch:

```bash
make wif-check ENV=dev
```

```text
  git remote : inTulsa/owc_okwire_pipeline
  dev tfvars : inTulsa/owc_okwire_pipeline
  OK: exact match
```

The git remote is the best available source for the casing, and `wif-check`
passing means there is nothing more to do here.

<details>
<summary>Only if a real Actions run later fails to authenticate: print the claim GitHub actually sends</summary>

**This is GitHub Actions YAML, not a shell command.** It goes in a step inside
a workflow file and cannot run on your laptop — `ACTIONS_ID_TOKEN_REQUEST_TOKEN`
exists only inside a runner with `id-token: write`. Pasting it into a terminal
gets you `zsh: command not found: name:` and an empty-input traceback.

```yaml
- name: show the OIDC repository claim
  run: |
    TOKEN=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https://github.com/$GITHUB_REPOSITORY_OWNER" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["value"])')
    echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["repository"])'
```

Whatever it prints is the string `attribute_condition` must equal exactly.

</details>

**Without it, any GitHub repository on earth can mint tokens for this
project.** It is the most common WIF misconfiguration and a full compromise.
The module's variable validation refuses an empty or wildcard value, and this
output exists specifically so the condition is visible in every plan diff.

For prod, also set `allowed_refs = ["refs/heads/prod"]`. Branch is the
environment here, so that single line is what stops any branch other than
`prod` — or a fork's pull request — from deploying to production, enforced by
GCP rather than by repo settings.

### Confirm the deployer can actually deploy

WIF controls *who* may assume the deployer service account. It says nothing
about what that account is allowed to do once assumed — and those are the two
things it is easy to conflate.

Everything you have run so far went through **your** credentials. GitHub
Actions runs the identical Terraform as `sa-<name_prefix>-deployer-1`, so "the apply
worked on my laptop" is not evidence that CI can run it:

```bash
make deployer-check ENV=dev
```

```text
>> deployer-check OK: sa-owc-dpar-d-deployer-1@owc-dpar-d.iam.gserviceaccount.com has all 14 project roles
```

The roles are granted by the step 5 apply, so a pass here usually means only
that you did step 5. It is worth one second anyway, because the failure it
catches is genuinely hard to read: the deployer administers every *resource*
in the project, but managing the project's **IAM policy** and its **WIF pool**
are two more permissions on top of that, and without them a CI run dies during
`terraform refresh` with 23 near-identical 403s that each name the role being
granted rather than the role that is missing:

```text
Error retrieving IAM policy for project "owc-dpar-d":
googleapi: Error 403: The caller does not have permission, forbidden
```

The two to know about, because neither is implied by the others:

| Role | Why |
|---|---|
| `roles/resourcemanager.projectIamAdmin` | Every `google_project_iam_member` read-modify-writes the project IAM policy. All 22 of them need `getIamPolicy` just to refresh. |
| `roles/iam.workloadIdentityPoolAdmin` | `roles/iam.serviceAccountAdmin` contains **zero** `workloadIdentityPools` permissions. Managing service accounts and managing WIF pools are separate roles. |

Both are predefined — there are no custom roles in this project. The check
parses its expected list straight out of `modules/wif/main.tf`, so adding a
role there cannot leave the check behind.

Wire the outputs into GitHub as **repository variables**:

```bash
make tf-output ENV=dev NAME=workload_identity_provider
make tf-output ENV=dev NAME=deployer_service_account
```

Those two become GitHub repository variables. **The full GitHub Actions
setup — all seven variables plus the two environments and the approval gate —
is in [`04-deployment.md`](04-deployment.md#setting-up-github-actions).**
Nothing in it is needed to deploy by hand.

Plus `PROJECT_ID_DEV`, `PROJECT_ID_PROD`, `REGION`, and the `_PROD` variants.

## 7. Verify the identity separation

Each pipeline has its own service account, and every grant is scoped to a
specific resource. Confirm the separation is real:

```bash
ENV=dev PROJECT=owc-dpar-d

# The enrollment SA must NOT be able to read the Snowflake secret.
gcloud secrets get-iam-policy sm-$PREFIX-snowflake-password-1 --project=$PROJECT --format=json \
  | grep -q "cr-$PREFIX-enrollment-1" \
  && echo "PROBLEM: enrollment can read the Snowflake secret" \
  || echo "OK: enrollment has no secret access"

# The lightcast SA must NOT be able to write the scrape cache.
gcloud storage buckets get-iam-policy gs://gcs-$PREFIX-enrollment-state-1 --format=json \
  | grep -q "cr-$PREFIX-lightcast-1" \
  && echo "PROBLEM: lightcast can write the scrape cache" \
  || echo "OK: lightcast has no access to the enrollment state bucket"

# PowerBI reads owc_marts and NOTHING else — not staging (unvalidated data),
# not ops (the run manifest).
for ds in owc_staging owc_ops; do
  bq show --format=prettyjson $PROJECT:$ds | grep -q "sa-$PREFIX-powerbi-1" \
    && echo "PROBLEM: PowerBI has a grant on $ds" \
    || echo "OK: PowerBI has no grant on $ds"
done
```

## 8. Region co-location

`location` feeds both the GCS buckets and all three BigQuery datasets from one
variable. **This is mandatory, not a preference:** a load job from a bucket in
one location into a dataset in another fails outright. Never set them
separately, and never mix them between environments you plan to copy data
between.

## 9. Smoke test

> **Point the jobs at the image first.** A Cloud Run job pins an image
> **digest**, and that field is in `lifecycle.ignore_changes` — so
> `terraform apply` will never move a job onto a newly built image, and
> `make build` only pushes it. Without this step a rebuilt fix is pushed to
> the registry while the jobs keep running the old digest, silently, because
> the tag moved but the digest did not.
>
> ```bash
> make set-image ENV=dev      # move both jobs onto the newest build
> make which-image ENV=dev    # confirm they match
> ```
>
> `make deploy ENV=dev` does build + set-image in one step.


```bash
gcloud run jobs execute $(make -s tf-output ENV=dev NAME=lightcast_job) \
  --region us-central1 --project owc-dpar-d \
  --args="run,lightcast,--dataset,dim_area" --tasks=1 --wait

gcloud run jobs execute $(make -s tf-output ENV=dev NAME=enrollment_job) \
  --region us-central1 --project owc-dpar-d --wait
```

`make tf-output ENV=dev` with no `NAME` lists everything, including the job
names, bucket names, and service-account emails the runbook refers to.

### What success looks like

The lightcast smoke test uses `--limit`, and **a row-limited run deliberately
does not publish**. Its rows are a truncation of the real result, so copying
them into `owc_marts` would replace a production table with a sample. Expect:

```text
extract_finished  dim_area  rows=78
bq_load_finished            rows=78
publish_skipped_row_limited rows=78
pipeline_succeeded
```

So after a successful smoke test, `owc_marts` will **not** contain
`dim_area` — that is correct, not a failure. The manifest records the run as
`success_limited`, a status that `previous_successful()` excludes so it cannot
become the baseline the next real run is compared against.

Confirm it succeeded from the manifest rather than from marts:

```bash
bq query --project_id=owc-dpar-d --use_legacy_sql=false \
'SELECT pipeline, dataset, status, row_count, duration_seconds
 FROM `owc_ops.pipeline_runs` ORDER BY started_at DESC LIMIT 5'
```

### Verifying the publish path

To exercise snapshot → table copy, run one **small dimension with no limit**.
`dim_area` is 78 rows, so this is cheap:

```bash
gcloud run jobs execute cr-owc-dpar-d-lightcast-1 --region us-central1 \
  --project owc-dpar-d --args="run,lightcast,--dataset,dim_area" \
  --tasks=1 --wait
```

Then check all three landed:

```bash
bq ls --project_id=owc-dpar-d owc_marts   # dim_area TABLE
bq ls --project_id=owc-dpar-d owc_ops     # a dim_area__<run_id> snapshot
```

Then confirm the manifest recorded both:

```bash
bq query --use_legacy_sql=false --project_id=owc-dpar-d \
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

- `allowed_refs = ["refs/heads/prod"]`
- Prod deploys when the `prod` branch is pushed, which in practice means
  merging a pull request from `dev`. Protect the `prod` branch to require
  that review — required reviewers on the GitHub *environment* needs a paid
  plan on a private repo, and without it the environment exists but gates
  nothing. See [`04-deployment.md`](04-deployment.md#the-gate-on-production).
- Leave `raw_bucket_force_destroy = false`.
