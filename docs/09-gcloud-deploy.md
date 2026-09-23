# Deploy

**Start here. This is the only deploy procedure.** It runs entirely in Google
Cloud Shell — nothing installed on your machine, no GitHub Actions, and no
`projectIamAdmin` on Terraform.

Six steps, ~20 minutes. Every command is idempotent: re-running is how you
repair a partial run.

---

## 1. Get the code into Cloud Shell {#get-the-code}

Open Cloud Shell from the GCP console (**⌨** in the top bar). Then, in
preference order:

**Clone it.** Simplest, and `.git` comes with it — which `make build` needs to
tag images with the commit they came from:

```bash
cd ~ && git clone https://github.com/inTulsa/owc_okwire_pipeline.git owc && cd owc
```

A private repo will ask for credentials; `gh auth login` or an HTTPS token
both work. This is not what OMES ruled out — their constraint is that *their
projects* cannot federate a personal GitHub account for automated deploys. A
person cloning a repo they own involves no GCP identity.

**Or upload it** if you would rather not authenticate to GitHub. The **⋮**
menu in the Cloud Shell toolbar has **Upload**; the Cloud Shell Editor takes
drag-and-drop. Send a **tarball, not the folder** — a folder upload carries
`.venv` and `.env`, and `.env` holds the Snowflake password:

```bash
# on your machine
tar czf owc.tar.gz --exclude='.venv' --exclude='.terraform' \
  --exclude='.env' --exclude='exports' owc_okwire_pipeline
```

```bash
# in Cloud Shell, after uploading
mkdir -p ~/owc && tar xzf ~/owc.tar.gz --strip-components=1 -C ~/owc && cd ~/owc
```

**Or from the project's own copy**, once step 4 has run at least once. This is
the path for anyone with GCP access but no GitHub access:

```bash
mkdir -p ~/owc && cd ~/owc \
  && gcloud storage cat gs://gcs-owc-dpar-d-source-1/latest.tar.gz | tar xz
```

> Work under `~`. Cloud Shell only persists `$HOME`, and it deletes even that
> after 120 days of inactivity.

## 2. Authenticate Terraform {#shell-setup}

Cloud Shell logs `gcloud` in for you. It does **not** log Terraform in, and
that is the half people skip.

```bash
eval "$(make -s env-exports ENV=dev)"
gcloud config set project $PROJECT
gcloud auth application-default login
gcloud auth application-default set-quota-project $PROJECT
```

`env-exports` sets `$PROJECT`, `$PREFIX`, `$REGION` from that environment's
`terraform.tfvars`, so they cannot drift from what Terraform builds. `make`
targets read the project themselves and need none of it.

The quota project is not optional. Terraform's GCS backend bills every call to
whatever `quota_project_id` sits in your ADC; an inactive one makes every call
return `404`, which Terraform reports as `storage: bucket doesn't exist`.

## 3. Check the environment

```bash
make doctor
```

The green light before anything creates a resource. It must end `Ready.` —
it exits non-zero if a **Deploy** tool or either credential is missing, which
is why it comes after step 2 and not before.

Warnings in the **Development** group are fine: the deploy path needs no
virtualenv, no `uv` and not Python 3.12.

## 4. Create the identities — privileged, once per project

The **only** step needing `serviceAccountAdmin` + `projectIamAdmin`. It
creates the six service accounts, their project IAM, the 16 API enables, and
the state and source buckets.

Look at it first — `--dry-run` prints every command, shell-quoted, and
**creates nothing at all**:

```bash
make gcloud-admin-dry-run ENV=dev
```

If you do not hold those roles, send that output to OMES. Otherwise run it
for real — the dry run above has not changed the project:

```bash
make gcloud-admin ENV=dev
make source-push  ENV=dev     # mirror the repo into the project
make iam-check    ENV=dev     # prove it landed
```

`iam-check` is the artifact to send back to OMES: it confirms the six
identities exist, the Terraform principal has all ten roles it needs, and that
it holds **none** of the six it must not.

The Terraform principal defaults to your own account. When OMES names theirs,
re-run — idempotent, nothing else changes:

```bash
make gcloud-admin ENV=dev TF_PRINCIPAL=serviceAccount:tf@their-proj.iam.gserviceaccount.com
```

## 5. Stand it up {#stand-it-up}

```bash
make up ENV=dev
```

**This stops partway on a new project and tells you to store the Snowflake
password.** That is by design: the secret *container* is a Terraform resource
that does not exist until this command creates it, and the *value* must exist
before the same command creates the Cloud Run jobs — the lightcast job
resolves `versions/latest` at creation time, and `latest` cannot resolve to
nothing.

```bash
printf '%s' 'THE_PASSWORD' | \
  gcloud secrets versions add sm-$PREFIX-snowflake-password-1 \
    --data-file=- --project $PROJECT
```

```bash
make up ENV=dev               # everything before the secret is now a no-op
```

On every later run it goes straight through. What it does, in order:

| | |
|---|---|
| `iam-check` | the identities and buckets are there |
| `tf-reinit` | adopt the state bucket named in `backend.tf` |
| `tf-bootstrap` | Artifact Registry + the secret container |
| `build` | Cloud Build → an image pinned by digest |
| `tf-apply` | everything else, including the Cloud Run jobs |
| `set-image` | point both jobs at that digest — `terraform apply` never will |
| `verify-separation` | each identity reaches only what it should |

Any of those can be run on its own with `make <target> ENV=dev`.

## 6. Prove it works

```bash
make smoke ENV=dev
```

One real run of each pipeline — `dim_area` is 78 rows, unlimited, so it
actually publishes — then the run manifest. Look for `status = success`.

---

## Then prod

The same six steps with `ENV=prod`. The two environments differ in exactly
four settings, listed in
[`03-gcp-setup.md`](03-gcp-setup.md#what-prod-does-differently).

## Why it is split this way

Three pieces of OMES feedback, and what each became:

> **"your terraform should not write IAM on each run … projectIamAdmin and
> serviceAccountAdmin is too much for terraform process, we should be able to
> manual create the resources needed, and then use lower permissions on the
> additional runs."**

Every `google_project_iam_member` read-modify-writes the project IAM policy,
so all 24 needed `getIamPolicy` **to refresh** — on runs that changed nothing.
Those, plus the seven service accounts and the API enables, moved to
[`infra/gcloud/01-admin-identities.sh`](../infra/gcloud/01-admin-identities.sh)
— step 4, once.

> **"we can not hook up your personal Github, but we can hook up your instance
> with the state once you work with Jason Thornhill."**

`enable_wif = false` in both environments: no federation pool, no OIDC
provider, no deployer service account. That single flag removes the largest
concentration of privilege in the config — the deployer held 13 project roles
including all three of `projectIamAdmin`, `serviceAccountAdmin` and
`workloadIdentityPoolAdmin`.

Nothing about the pipelines changed. Same jobs, schedules, alerts and data.

### Where the line is drawn

**Terraform creates resources. It does not create identities, and it never
reads or writes the project IAM policy.**

| | Created by | Needs |
|---|---|---|
| APIs, service accounts, project IAM, `actAs`, state + source buckets | step 4 | `serviceAccountAdmin`, `projectIamAdmin`, `serviceUsageAdmin` |
| Buckets, datasets, tables, registry, secret, jobs, schedulers, alerts | Terraform | resource admin only |
| **Resource-scoped** IAM — bucket prefix, dataset `dataEditor`, secret accessor, registry reader, job `run.invoker` | Terraform | nothing extra |

That last row is the only IAM Terraform still writes. It lives in the policy
of a resource Terraform just created, and `storage.admin` on a bucket already
contains `setIamPolicy` on that bucket — you cannot create the bucket without
it. It also cannot move to step 4 without breaking ordering: the build
identity needs `artifactregistry.writer` on a registry that does not exist
yet, and the lightcast job will not *create* unless its runtime identity can
already read the secret.

If OMES wants that row moved too, it becomes a third script run between
`tf-bootstrap` and `tf-apply`. It is the only part of this design still
negotiable.

### The roles, before and after

**Terraform needs** — all resource administration, nothing about IAM policy:

```
roles/serviceusage.serviceUsageConsumer   roles/cloudscheduler.admin
roles/storage.admin                       roles/secretmanager.admin
roles/bigquery.admin                      roles/artifactregistry.admin
roles/run.developer                       roles/monitoring.editor
roles/cloudbuild.builds.editor            roles/logging.configWriter
```

plus `roles/iam.serviceAccountUser` on five specific accounts — per-account,
not project-wide, because attaching an identity to a Cloud Run job, a
Scheduler job, a build or a scheduled query requires `actAs` on it.

**No longer needed. `make iam-check` fails if they are still granted:**

```
roles/resourcemanager.projectIamAdmin     roles/iam.workloadIdentityPoolAdmin
roles/iam.serviceAccountAdmin             roles/serviceusage.serviceUsageAdmin
roles/owner                               roles/editor
```

## Working in Cloud Shell

- **Sessions end after ~20 min idle, 12 h maximum.** Cloud Shell runs inside
  tmux, so `tmux attach` recovers a dropped `terraform apply`. Do that rather
  than starting a second apply against the same state.
- **Only `$HOME` persists**, and it is deleted after 120 days of inactivity.
  Re-clone, or fetch from the source bucket.
- **Nothing here uses Docker.** `make build` is a `gcloud builds submit`; the
  daemon Cloud Shell happens to run is unused.
- `cloudshell edit <file>` opens the built-in editor.

Failure modes and their fixes are in
[`02-runbook.md`](02-runbook.md#cloud-shell-and-the-reduced-permission-set).

## Migrating a project applied with the old configuration {#migrating}

Only relevant where Terraform previously created the identities. A fresh
project has nothing to migrate.

`manage_identities = false` makes Terraform want to **destroy** the service
accounts it is now told not to manage. Forget them first — this removes them
from state, it does not delete them:

```bash
cd infra/terraform/envs/dev
terraform state list \
  | grep -E 'google_(service_account|project_iam_member|project_service|project_service_identity|service_account_iam_member)\.' \
  | grep -v 'module.wif' > /tmp/to-forget.txt

cat /tmp/to-forget.txt                        # read before running the next line
xargs -a /tmp/to-forget.txt -n1 terraform state rm
terraform plan                                # only module.wif.* should be destroyed
```

The WIF module is the exception: there you **do** want the resources gone. A
federation pool nobody uses is a way in that nobody is watching.

## What this defers

GitHub Actions. `.github/workflows/` is committed, correct and inert — the
repository variables are unset and the WIF provider it authenticates against
is not built. `make deployer-check` and `make gh-vars` refuse with an
explanation rather than reporting the missing deployer as a permission
problem.

When OMES federates their own instance: set `enable_wif = true`, apply once
with an account holding `workloadIdentityPoolAdmin`, then follow
[`04-deployment.md`](04-deployment.md#setting-up-github-actions). Nothing here
has to be undone.
