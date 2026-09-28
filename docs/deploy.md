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

Order matters here: authenticate **as yourself** first, then switch the shell
onto the deploy identity.

```bash
gcloud auth application-default login
```

```bash
eval "$(make -s env-exports ENV=dev)"
```

```bash
gcloud config set project $PROJECT
gcloud auth application-default set-quota-project $PROJECT
```

`env-exports` sets `$PROJECT`, `$PREFIX`, `$REGION` from that environment's
`terraform.tfvars`, so they cannot drift from what Terraform builds. It also
sets the two variables that put this shell on the deploy identity. `make`
targets read the project themselves and need none of it.

### You deploy as a service account, not as yourself {#deploy-identity}

Nobody holds the resource-admin roles. They belong to

```
sa-<prefix>-deploy-1@<project>.iam.gserviceaccount.com
```

and you are granted exactly one thing — `roles/iam.serviceAccountTokenCreator`
on that account. You deploy by impersonating it.

Three things follow, and they are the reason it is built this way:

- **No human holds an admin-level role**, which is OMES's rule. Your own
  account has one binding in the project.
- **Every action stays attributable.** An impersonated call records both the
  service account and the person who minted the token, so "who ran this
  apply" is still answerable.
- **Revoking is one binding.** Removing someone's `tokenCreator` removes all
  of it at once, with nothing to unpick across eleven roles and five
  accounts.

`env-exports` sets both halves — gcloud reads
`CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT`, and the Terraform google
provider reads `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` — so every command in
that shell runs as the deploy account. Nothing else has to be passed.

Confirm it before going further:

```bash
make deploy-identity ENV=dev
```

It answers two questions separately: does the account exist, and can you
impersonate it. A missing account is an admin step; a missing `tokenCreator`
is one binding to ask for.

**To deploy as yourself instead** — a rehearsal on a project you own, where
you are already `roles/owner` and no deploy account exists:

```bash
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT GOOGLE_IMPERSONATE_SERVICE_ACCOUNT
```

An admin running the one privileged step never evals `env-exports`, so their
step is unaffected by any of this.

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

Downloads the pinned version, verifies its published SHA256, puts it in
`~/bin`, and adds that to `PATH` in `~/.bashrc` so later sessions have it.

**The shell you are in started before that**, so it needs the export once —
the installer prints the exact line, or just open a new Cloud Shell tab.
Then re-run `make doctor`; it must say `ok terraform`.

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

## 5a. If you are NOT the project admin

The normal case, and the only step anyone else touches. Pick whichever the
admin will actually agree to — all three produce the same result.

First, do your own half. It needs no elevated rights and it keeps their
file down to identity work alone:

```bash
make prep ENV=dev
```

Three steps: the 16 API enables, the BigQuery Data Transfer agent, and the
two GCS buckets. All things your account can already do, so there is no
reason for them to be in a request to somebody else — and a bucket creation
sitting in the middle of an IAM request is a question, which costs days.

### They run one file (no repo, no roles granted to you)

The usual answer when an admin will not grant you `serviceAccountAdmin`.

**You** generate the file. This touches nothing in GCP:

```bash
make omes-script ENV=dev > owc-setup.sh
```

It is standalone: every command written out, no dependencies but `gcloud`,
readable start to finish before anyone runs it.

Get it to them. From Cloud Shell, this downloads it to your own machine so
you can send it:

```bash
cloudshell download owc-setup.sh
```

On a call, `cat owc-setup.sh` and let them copy it straight into their own
Cloud Shell instead.

The file explains how to run itself — you do not have to write instructions
to go with it. Its header says, in order: open Cloud Shell on the project,
upload via the toolbar's **⋮ → Upload → File**, then

```text
gcloud config set project <project>
bash ~/owc-setup.sh
```

**They** run it, with their project set to this one:

```bash
bash owc-setup.sh
```

You cannot run it yourself — it fails at the fourth step with a 403 on
`iam.serviceAccounts.create`, which is exactly the permission this whole
split exists to avoid needing. It stops there rather than half-finishing,
and the steps before it are idempotent, so a mistaken run costs nothing.

Four steps, and nothing but identities: create the seven service accounts
(six runtime, one deploy), grant the runtime ones their project roles, give
the **deploy account** the resource-admin roles and `actAs` on the five it
attaches, and grant **you** `tokenCreator` on the deploy account. It refuses
to run against the wrong project, skips anything that already exists, and is
safe to re-run.

The only thing it grants a human is the right to impersonate one service
account. Nothing in it gives you a role that can administer IAM, or any
resource-admin role at all — see [the deploy identity](#deploy-identity).

### They grant you the two roles for the call

Faster if they are willing. `make omes-request ENV=dev` prints the ask and
the revoke. You run `make gcloud-admin ENV=dev` in between, then
`make iam-check ENV=dev STRICT=1` in front of them — it **fails** while
either role is still attached, so it is the receipt.

### They clone this repo and run it

```bash
git clone https://github.com/inTulsa/owc_okwire_pipeline.git owc && cd owc
./infra/gcloud/01-admin-identities.sh <project> --principal <you> --dry-run
```

Same script the file above is generated from. `--dry-run` first.

---

Whichever they choose, confirm it landed and continue at step 6:

```bash
make access-check ENV=dev     # verdict should now say you can deploy
```

If they would rather host Terraform state, ask for the bucket name in the
same conversation — they skip the state bucket, and you pass
`STATE_BUCKET=their-bucket` on every later command.

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

`iam-check` confirms the six identities exist, that you have all eleven roles
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
| **GCP, day to day** | `roles/iam.serviceAccountTokenCreator` on `sa-<prefix>-deploy-1` — **one binding, and the only one you hold** | Everything else: `make up`, `make build`, `make tf-apply`, `make smoke`, by impersonating that account. The eleven resource-admin roles live on it, not on you, and none of them can read or write the project IAM policy. See [the deploy identity](#deploy-identity). |
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
| `tf-init` | adopt the state bucket for this `PROJECT`, and print it |
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
inferred — they can read it, run it, or run the script themselves.

**`--principal` is required and is never defaulted.** It names the *person*
who will deploy, and the only thing they get is `tokenCreator` on the deploy
service account. The script used to fall back to whichever gcloud account was
active, which meant an admin running it from their own shell silently granted
themselves — so it now refuses rather than guess:

```bash
./infra/gcloud/01-admin-identities.sh owc-dpar-d --principal user:THE-PERSON@agency.ok.gov
```

If the deploying person is not decided yet, pass `--no-principal`. The deploy
account and all its roles are still created; only the grant that lets a human
use it is deferred.

If OMES is hosting Terraform state — *"we can hook up your instance with the
state"* — they add `--no-state-bucket`, tell you the bucket, and you set it in
**both** `terraform.tfvars` and `backend.tf` before step 5.

### `iam-check` will run in REDUCED mode there, and that is correct

None of the eleven roles you get includes `resourcemanager.projects.getIamPolicy`.
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
unproven claim — "eleven roles are enough" — is proven the first time it runs
in an OMES project, where you genuinely do not have more.

To close that gap before handing over, have OMES run step 4 on a project
where you are not owner, or drop owner on the test project *after* step 4 —
carefully, and only if someone else can still administer it.

## Then prod {#prod}

Prod runs the same steps with `ENV=prod`, but it is not a replay of dev. Three
things have to be settled first, and two of prod's differences change what a
mistake costs.

### Settle these before step 5

| | |
|---|---|
| **`snowflake_user` is a placeholder** | `envs/prod/terraform.tfvars` ships `REPLACE_ME@…` and the plan rejects it on purpose. Put the real reader account in first. |
| **Who deploys prod** | The privileged step runs **once** per project. Decide which person gets `tokenCreator` on `sa-owc-dpar-p-deploy-1` before it runs — see [the deploy identity](#deploy-identity). Adding someone later is one binding; taking resource-admin roles back off a person is not. |
| **Terraform state hosting** | [OPEN-ITEMS item 8](OPEN-ITEMS.md#state-hosting). Cheaper to answer now than to migrate state later. |

`owc-dpar-p` has none of its six service accounts yet, so the privileged step
there creates everything from nothing.

### Two differences that change the procedure

The [full four](gcp-reference.md#what-prod-does-differently) are in the
reference. These two matter while you are deploying:

- **`schedulers_paused = false` — the schedulers come up live.** `tf-apply`
  creates schedulers that fire on `pipelines.yml`'s real cron. A permissions
  mistake does not surface at your terminal; it surfaces as a 403 on the 1st
  of the month. This is why the proof below is not optional in prod.
- **`freshness_check_enabled = true`** — the freshness alert is armed from the
  first apply, so a pipeline that never runs starts alerting inside its grace
  window instead of sitting quietly.

### Prove the scheduler, not just the pipelines {#prove-the-scheduler}

`make smoke` runs each pipeline **as you**. Cloud Scheduler runs them as
`sa-<prefix>-scheduler-1`, which is a different identity needing a different
permission. A green smoke test and a scheduler that cannot start anything look
identical from outside — that is exactly what dev looked like for five days.

```bash
gcloud scheduler jobs run cs-$PREFIX-enrollment-monthly-1 --location $REGION --project $PROJECT
```

```bash
gcloud run jobs executions list --job cr-$PREFIX-enrollment-1 --region $REGION --project $PROJECT --limit 3
```

Read the **`RUN BY`** column, not the timestamp:

```text
RUN BY: sa-owc-dpar-p-scheduler-1@owc-dpar-p.iam.gserviceaccount.com   <- the scheduler started it
RUN BY: someone@agency.ok.gov                                          <- you started it
```

Only the first proves anything. Use **enrollment**: it short-circuits on its
cache, while lightcast fans out to 41 tasks and bills Lightcast's warehouse.

Prod's schedulers are already enabled, so `jobs run` works directly. In dev
they are paused and `jobs run` refuses with
`FAILED_PRECONDITION: Job.state must be ENABLED` — resume first, then pause
back afterwards.

If it returns 403, go to [ALERT 3](runbook.md#scheduler-403) and start with
the job's own IAM policy.

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
| **Resource-scoped** IAM — bucket prefix, dataset `dataEditor`, secret accessor, registry reader, job `run.developer` | Terraform | resource admin only |

That last row is the only IAM Terraform still writes. It lives in the policy
of a resource Terraform just created, and for most of those the resource-admin
role already carries it: `storage.admin` on a bucket contains `setIamPolicy`
on that bucket — you cannot create the bucket without it.

**Cloud Run jobs are the exception, and it decided one of the eleven roles.**
`roles/run.developer` does *not* contain `run.jobs.setIamPolicy`, so it cannot
write the scheduler binding in `modules/pipeline/job.tf` — an apply dies on
that one resource and the schedulers 403 forever. The deploy identity holds
`roles/run.admin` instead, which does. That is the one role in the list
broader than "administer the resource", and it is acceptable only because
[a service account holds it](#deploy-identity) rather than a person. It also cannot move to step 4 without breaking ordering: the build
identity needs `artifactregistry.writer` on a registry that does not exist
yet, and the lightcast job will not *create* unless its runtime identity can
already read the secret.

If OMES wants that row moved too, it becomes a third script run between
`tf-bootstrap` and `tf-apply`. It is the only part of this design still
negotiable.

### The roles, before and after

**The deploy service account holds** — all resource administration, nothing
that reads or writes the *project* IAM policy:

```
roles/serviceusage.serviceUsageConsumer   roles/cloudscheduler.admin
roles/storage.admin                       roles/secretmanager.admin
roles/bigquery.admin                      roles/artifactregistry.admin
roles/run.admin                           roles/monitoring.editor
roles/cloudbuild.builds.editor            roles/logging.configWriter
roles/logging.viewer
```

**A person holds** one binding: `roles/iam.serviceAccountTokenCreator` on
that account.

`logging.viewer` is there because the alerting in this system is log-based
and the runbook's diagnostics are `gcloud logging read`. `configWriter`
creates metrics and sinks; it does not read entries. Without the viewer role
an operator can see that an alert fired and nothing about why.

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

