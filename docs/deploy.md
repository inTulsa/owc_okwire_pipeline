# Deploy

**The whole procedure, and the only one.** Eight steps, about 20 minutes, run
entirely in Google Cloud Shell — nothing installed on your machine, no CI, and
no `projectIamAdmin` on Terraform.

Every command is idempotent. Re-running is how you repair a partial run, so
when something fails, fix it and start again from the top.

Aiming this at a different project — your own, for a rehearsal — is one extra
variable on every command: `PROJECT=your-project`. See
[Rehearsing against your own project](#rehearsing-against-your-own-project).

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

### Cloud Shell does not ship terraform

It ships a **stub** that prints apt install instructions. Install a real one
into `$HOME`, which is the only thing a Cloud Shell session keeps — apt puts
it under `/usr`, where it is gone next session:

```bash
make install-terraform
```

Downloads the pinned version, verifies its published SHA256, and puts it in
`~/bin`. Re-run `make doctor` afterwards; it must say `ok terraform`.

**Do not skip this on a MISSING terraform line.** The stub can exit zero, so
`terraform init && terraform apply` appears to succeed while creating
nothing — and the first symptom is a `NOT_FOUND` from Secret Manager several
steps later, pointing at the wrong thing entirely. Every `tf-*` target now
refuses to run rather than let that happen.

## 4. Find out what you are allowed to do {#access-check}

On a project you created, you can do everything. On one you were given
access to, you probably cannot — and the failure looks like a wall of
permission errors three steps later. Ask first. This is read-only and needs
no special rights:

```bash
make access-check ENV=dev
```

It reports three things: whether you can run the deploy, whether you can run
the privileged step, and what already exists in the project. The verdict at
the bottom tells you which of the two paths below you are on.

## 5a. If you are NOT the project admin — send the request

This is the normal case on an OMES project, and it is the **only** step
anybody else has to do.

```bash
make omes-request ENV=dev > owc-setup-request.txt
```

Send that file. It is self-contained — the recipient needs no repo, no
`make`, no Terraform. It states which three roles they need, what the
commands create, why Terraform is not doing it, and every command verbatim
so they can read before running.

Name yourself as the deploy principal, which the request already does from
your active gcloud account. To name a different one:

```bash
make omes-request ENV=dev TF_PRINCIPAL=serviceAccount:tf@their-project.iam.gserviceaccount.com
```

When they reply that it is done, confirm it from your side and continue at
step 6:

```bash
make access-check ENV=dev     # verdict should now say you can deploy
make iam-check    ENV=dev
```

If OMES would rather host Terraform state themselves, ask for the bucket
name in the same message — they run their half with `--no-state-bucket`, and
you pass `STATE_BUCKET=their-bucket` on every later command.

## 5b. If you ARE the project admin — run it yourself

Your own test project, or an OMES project where they granted you the three
roles. Look at it first; `--dry-run` creates nothing:

```bash
make gcloud-admin-dry-run ENV=dev
make gcloud-admin ENV=dev
```

## 6. Publish the code and confirm the setup

Either path lands here.

```bash
make source-push ENV=dev     # mirror the repo into the project
make iam-check   ENV=dev     # confirm step 5 landed
```

`iam-check` confirms the six identities exist, that you have all ten roles
the deploy needs, and that you hold none of the six you should not. That last
group is a warning, not a failure — excess privilege does not stop a deploy
working, it stops the deploy proving anything. `STRICT=1` makes it a failure,
which is the audit to ask OMES for.

On an OMES project this runs in REDUCED mode and skips the role assertions,
because you will not be able to read the project IAM policy. That is correct:
see [Running this in an OMES project](#omes).

### Access you need granted {#access}

Tooling is the easy half. These take longer to obtain, so start them early.

Two levels, and only the first is hard to get.

| Access | Scope | Needed for |
|---|---|---|
| **GCP, privileged** | `roles/iam.serviceAccountAdmin` + `roles/resourcemanager.projectIamAdmin` + `roles/serviceusage.serviceUsageAdmin` | `make gcloud-admin`, **once per project**, and `make iam-check STRICT=1` afterwards. In an OMES project this is theirs to run, from `make gcloud-admin-dry-run` output. |
| **GCP, day to day** | the ten resource-admin roles `make gcloud-admin` grants, plus `serviceAccountUser` on five accounts | Everything else: `make up`, `make build`, `make tf-apply`, `make smoke`. Deliberately cannot read or write the project IAM policy. |
| **Snowflake** | the reader account login + password | The lightcast pipeline. Password goes to Secret Manager, never into Terraform. |
| **Alert distribution list** | an address you can add members to | `alert_emails`. Use a list, not a person, so the rotation changes without a Terraform change. |
| **Billing account** | `roles/billing.costsManager` | **Only** if you enable the budget alert. It is off by default. |
| **GitHub repo** | read | Only to `git clone` the repo into Cloud Shell. Uploading a tarball or fetching the project's mirror needs no GitHub at all. |

## 7. Stand it up {#stand-it-up}

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

## 8. Prove it works

```bash
make smoke ENV=dev
```

One real run of each pipeline — `dim_area` is 78 rows, unlimited, so it
actually publishes — then the run manifest. Look for `status = success`.

---

## Running this in an OMES project {#omes}

The six steps are the same. What differs is **who runs step 4**, and that
changes what the other steps look like.

### Step 4 is theirs, not yours

You will not hold `serviceAccountAdmin` or `projectIamAdmin` on `owc-dpar-d`
or `owc-dpar-p`. So:

```bash
make gcloud-admin-dry-run ENV=dev
```

Send that output to OMES. It is every command, shell-quoted, with nothing
inferred — they can read it, run it, or run the script themselves. Ask them
to name you as the Terraform principal:

```bash
./infra/gcloud/01-admin-identities.sh owc-dpar-d   --principal user:gabriel.torianyk@tulsaforyou.com
```

If OMES is hosting Terraform state — *"we can hook up your instance with the
state"* — they add `--no-state-bucket`, tell you the bucket, and you set it in
**both** `terraform.tfvars` and `backend.tf` before step 5.

### `iam-check` will run in REDUCED mode there, and that is correct

None of the ten roles you get includes `resourcemanager.projects.getIamPolicy`.
So in an OMES project the check cannot read the project IAM policy, says so,
and skips the role assertions:

```text
Running in REDUCED mode
  This account cannot read the project IAM policy, so the role
  assertions below are skipped. That is the expected state for the
  Terraform principal, and it is its own proof: an account that cannot
  call getIamPolicy does not hold roles/resourcemanager.projectIamAdmin.
```

Everything a deploy depends on is still checked — the six identities, the
buckets, the APIs, ADC, `actAs`. The full audit is something **OMES** runs,
with their own account:

```bash
make iam-check ENV=dev STRICT=1
```

That is the report to ask them for, and the one that answers Stephen's
objection on their own terms rather than yours.

### What a rehearsal on your own project cannot prove

On a project you created you are `roles/owner`, so every permission check
succeeds whether or not the reduced role set is sufficient. `iam-check` warns
about this rather than failing — excess privilege does not stop a deploy, it
stops the deploy being *evidence*:

```text
warn     STILL HAS roles/owner
         This does NOT block a deploy — the roles above are more than
         Terraform needs, not less. It does mean this run proves nothing
         about the reduced role set, because you would succeed regardless.
```

Everything else rehearses faithfully: the script's output, the resource
graph, the ordering, the two-pass `make up`, the smoke test. The one
unproven claim — "ten roles are enough" — is proven the first time it runs
in an OMES project, where you genuinely do not have more.

To close that gap before handing over, have OMES run step 4 on a project
where you are not owner, or drop owner on the test project *after* step 4 —
carefully, and only if someone else can still administer it.

## Then prod

The same six steps with `ENV=prod`. The two environments differ in exactly
four settings, listed in
[`gcp-reference.md`](gcp-reference.md#what-prod-does-differently).

## Rehearsing against your own project

The same six steps with one extra variable. Nothing is edited, nothing is
committed, nothing has to be changed back:

```bash
make gcloud-admin ENV=dev PROJECT=my-test-project
make up           ENV=dev PROJECT=my-test-project
make smoke        ENV=dev PROJECT=my-test-project
```

`PROJECT` reaches all three places that matter — the gcloud steps that create
the identities, the `-var` values Terraform applies with, and the state bucket
passed to `terraform init`.

Use `ENV=dev`. Prod sets `schedulers_paused = false`, so an apply there
creates live schedulers that fire the monthly schedule at Lightcast's
warehouse from whatever project you aimed it at.

One thing a rehearsal on your own project cannot prove: you will be
`roles/owner` there, so every permission check passes whether or not the ten
roles are sufficient. `iam-check` warns rather than failing — see
[Running this in an OMES project](#omes).

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

There is no CI in this repo. The Workload Identity Federation pool, the OIDC
provider, the deployer service account and the GitHub Actions workflows are
all deleted — the deployer alone held 13 project roles, including all three
of `projectIamAdmin`, `serviceAccountAdmin` and `workloadIdentityPoolAdmin`.
Deploys run from Cloud Shell, as a person.

If OMES federates their own instance later, that is a new deploy path built
against whatever they run, not a dormant one waiting in this repo. The git
history has the old one.

Nothing about the pipelines changed. Same jobs, schedules, alerts and data.

### Where the line is drawn

**Terraform creates resources. It does not create identities, and it never
reads or writes the project IAM policy.**

| | Created by | Needs |
|---|---|---|
| APIs, service accounts, project IAM, `actAs`, state + source buckets | step 4, in gcloud | `serviceAccountAdmin`, `projectIamAdmin`, `serviceUsageAdmin` |
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
roles/resourcemanager.projectIamAdmin     roles/serviceusage.serviceUsageAdmin
roles/iam.serviceAccountAdmin             roles/iam.workloadIdentityPoolAdmin
roles/owner                               roles/editor
```

Holding one of these is a **warning**, not a failure: excess privilege does
not stop a deploy working, it stops the deploy proving anything.
`make iam-check ENV=dev STRICT=1` makes it a failure — that is the audit.

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
[`runbook.md`](runbook.md#cloud-shell-and-the-reduced-permission-set).

