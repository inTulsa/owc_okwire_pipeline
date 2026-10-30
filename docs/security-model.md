# Security model

**Who can do what in this project, and how each claim is proved rather than
asserted.**

Written for a reviewer who has not read the code. It covers the identity
design, the exact role set, the commands that verify it, and — deliberately
— the two places where the deployed reality is wider than the design claims.

- [The short version](#short-version)
- [Three classes of principal](#three-classes)
- [What the deploy identity holds](#deploy-roles)
- [What it provably cannot do](#cannot-do)
- [How each claim is verified](#verification)
- [Where the current set is wider than the design claims](#known-gaps)
- [Runtime identities and the data boundary](#runtime)
- [The one documented exception: the PowerBI key](#powerbi-key)
- [The open question for production](#prod-question)

---

## The short version {#short-version}

**No human account needs an administrative role to operate this platform.**

Resource administration belongs to one service account per project,
`sa-<prefix>-deploy-1`, which nobody logs in as. A person who deploys holds
exactly one binding — `roles/iam.serviceAccountTokenCreator` on that account
— and works by impersonating it.

Three properties follow, and each is checkable:

- **No human holds an admin-level role.** A deployer's entry in the project
  IAM policy is one `tokenCreator` binding on one service account.
- **Every action stays attributable.** An impersonated call records both the
  service account and the person who minted the token, so "who ran this"
  remains answerable in the audit log.
- **Revoking is one binding**, not eleven roles and five `actAs` grants
  unpicked across several resources.

The design responds to three specific pieces of platform-team feedback; what
each one became is recorded in
[`deploy.md`](deploy.md#why-it-is-split-this-way).

---

## Three classes of principal {#three-classes}

| Class | Who | Holds | When it acts |
|---|---|---|---|
| **Administrator** | A platform admin | `serviceAccountAdmin`, `projectIamAdmin`, `serviceUsageAdmin` | **Once per project.** Creates the seven service accounts, grants project IAM, enables APIs, creates the state and source buckets. Never again. |
| **Deploy identity** | `sa-<prefix>-deploy-1` — a service account, no login | Eleven resource-admin roles, plus `actAs` on five specific accounts | Every deploy. Creates and updates resources. Cannot read or write project IAM. |
| **Runtime identities** | Six service accounts, one per job | Narrow, mostly resource-scoped grants | Whenever a pipeline runs. Each reaches only its own inputs and outputs. |

**The administrator's step is genuinely one-time and genuinely separable.**
It can be handed over as a standalone script that grants the repo's operator
nothing but `tokenCreator`, requires no checkout, and can be read start to
finish before it is run:

```bash
make omes-script ENV=prod > owc-setup.sh
```

To review without generating a file, `make gcloud-admin-dry-run ENV=prod`
prints every command shell-quoted, with nothing inferred.

---

## What the deploy identity holds {#deploy-roles}

Eleven predefined roles. **This repo defines and grants no custom roles** —
see
[ADR-010](architecture.md#adr-010-rollback-from-the-gcs-parquet-not-a-bigquery-snapshot)
— which is what makes the set reviewable without reading the code. (An
organization may separately attach its own custom roles to a project; on
`owc-dpar-d` the org's storage-scanning agent holds two. Those are the
organization's, not this platform's.)

| Role | What it is for |
|---|---|
| `roles/serviceusage.serviceUsageConsumer` | Use the already-enabled APIs. **Not** `serviceUsageAdmin` — APIs are enabled in the one-time admin step, so Terraform never enables one. |
| `roles/storage.admin` | The two buckets and their own bucket-level policies. |
| `roles/bigquery.admin` | Datasets, tables, views, and the freshness scheduled query. |
| `roles/run.admin` | The two Cloud Run jobs **and** the scheduler's binding on them. See [the one broad role](#run-admin) below. |
| `roles/cloudscheduler.admin` | The scheduler jobs. |
| `roles/secretmanager.admin` | The secret **container** only. The value is added by hand and never enters Terraform state. |
| `roles/artifactregistry.admin` | The image registry. |
| `roles/monitoring.editor` | Six alert policies and one notification channel. See [known gaps](#known-gaps). |
| `roles/logging.configWriter` | Log-based metrics and sinks. Does not read entries. |
| `roles/logging.viewer` | Reading entries. The alerting here is log-based, so an operator without this can see *that* an alert fired and nothing about why. |
| `roles/cloudbuild.builds.editor` | `make build` submits a Cloud Build. Droppable if builds ever move to platform-team CI. |

Plus `roles/iam.serviceAccountUser` on **five specific accounts**, not
project-wide — attaching an identity to a Cloud Run job, a scheduler job, a
build or a scheduled query requires `actAs` on that identity.

The canonical list is `TF_PRINCIPAL_ROLES` in
[`infra/gcloud/names.sh`](../infra/gcloud/names.sh), which is what the setup
script and the verifier both read. This table is generated from reading it;
the file is the source of truth.

### The one role broader than "administer this resource" {#run-admin}

`roles/run.admin` is the exception, and it is deliberate. Terraform writes
the IAM binding that lets Cloud Scheduler start the jobs, which needs
`run.jobs.setIamPolicy`. `roles/run.developer` does not carry it — with the
narrower role the apply dies on that one resource and the schedulers return
403 forever, silently, because the jobs still work by hand.

**It is acceptable only because a service account holds it**, not a person.
An organization that refuses it has a documented fallback: the setup script
attempts `run.admin`, falls back to `run.developer` on refusal, prints which
way it went, and prints the two follow-up commands the fallback needs. The
trade-off is in [`deploy.md`](deploy.md#run-admin-decision).

**That fallback has never been executed** — see
[OPEN-ITEMS: the scheduler-IAM fallback](OPEN-ITEMS.md#scheduler-fallback). It is reviewed code,
not tested code.

---

## What it provably cannot do {#cannot-do}

Six roles are asserted **absent**, and the verifier fails if any is attached:

```
roles/resourcemanager.projectIamAdmin     roles/serviceusage.serviceUsageAdmin
roles/iam.serviceAccountAdmin             roles/iam.workloadIdentityPoolAdmin
roles/owner                               roles/editor
```

The first four are the ones the platform team named, or their direct
consequences. What each one used to be needed for, and where that work went:

| Role | Was needed because | Now |
|---|---|---|
| `projectIamAdmin` | Every `google_project_iam_member` read-modify-writes the project IAM policy, so all 24 needed `getIamPolicy` merely to *refresh* | Moved to the one-time admin step |
| `serviceAccountAdmin` | Terraform created seven service accounts | Moved to the one-time admin step |
| `serviceUsageAdmin` | Terraform enabled fourteen APIs | Moved to the one-time admin step |
| `workloadIdentityPoolAdmin` | A GitHub Actions federation pool | **Not built at all.** There is no CI in this repo; deploys run from Cloud Shell, as a person impersonating the deploy account |

**Terraform creates resources. It does not create identities, and it never
reads or writes the project IAM policy.** The one kind of IAM it still writes
is resource-scoped — a bucket prefix, a dataset `dataEditor`, a secret
accessor — living in the policy of a resource it just created. For most of
those the resource-admin role already implies it: you cannot create a bucket
without `setIamPolicy` on that bucket. The full boundary is in
[`deploy.md`](deploy.md#where-the-line-is-drawn).

### The check that proves it by failing

In a project where the deploy identity is correctly scoped, `make iam-check`
**cannot read the project IAM policy at all**, and says so:

```text
Running in REDUCED mode
  This account cannot read the project IAM policy, so the role
  assertions below are skipped. That is the expected state for the
  Terraform principal, and it is its own proof: an account that cannot
  call getIamPolicy does not hold roles/resourcemanager.projectIamAdmin.
```

That is the strongest available evidence and it is self-demonstrating: the
inability to run the check *is* the result.

---

## How each claim is verified {#verification}

Nothing here asks to be taken on trust. Each command is read-only.

**The deploy identity's audit — run by an administrator**, since the deploy
identity deliberately cannot read the policy itself:

```bash
make iam-check ENV=prod STRICT=1
```

It confirms the seven identities exist, that the deploy account holds all
eleven roles, and that it holds none of the six forbidden ones. `STRICT=1`
turns excess privilege from a warning into a failure.

**Read what it audits precisely.** It checks **one principal** —
`TF_PRINCIPAL`, which defaults to `serviceAccount:sa-<prefix>-deploy-1`. A
clean `STRICT=1` run is a statement about the deploy account and about
nothing else. In particular it does **not**:

- **Audit human accounts.** A person holding `serviceUsageAdmin` does not
  make this command fail. Point it at them explicitly, one at a time:

  ```bash
  make iam-check ENV=dev STRICT=1 TF_PRINCIPAL=user:someone@agency.ok.gov
  ```

- **See roles inherited from the organization or folder.** It reads the
  *project* IAM policy, and an inherited binding does not appear there.
  This is not hypothetical on these projects: the administrator who ran the
  one-time setup successfully wrote the project IAM policy while holding no
  project-level `projectIamAdmin` or `owner`, so that grant is inherited and
  invisible to every check in this repo.

For a whole-project statement, read the policy directly — which is also the
artifact worth keeping as the record:

```bash
gcloud projects get-iam-policy owc-dpar-p --format=yaml
```

**The data-boundary assertions — run on every deploy:**

```bash
make verify-separation ENV=prod
```

```text
  OK       enrollment has no access to the Snowflake secret
  OK       lightcast has no access to the enrollment state bucket
  OK       PowerBI has no grant on owc_staging
  OK       PowerBI has no grant on owc_ops
  OK       control: PowerBI IS granted on owc_marts
```

**The last line is a positive control and it is the point.** Every other
assertion passes by *not* finding an account in a policy — which is also
exactly what happens when the lookup is broken, the name is misspelled, or
the caller cannot read the policy at all. The control asserts a grant that
*must* exist; if that one cannot be found, none of the negative results mean
anything and the command exits non-zero.

**What a rehearsal cannot prove.** On a project where the operator is
`roles/owner`, every permission check passes whether or not the reduced role
set is sufficient. `iam-check` warns rather than failing, because excess
privilege does not stop a deploy working — it stops the deploy being
evidence. The claim "eleven roles are enough" is proven the first time it
runs somewhere the operator genuinely has no more.

---

## Where the current set is wider than the design claims {#known-gaps}

Two, both disclosed rather than discovered.

**1. `roles/monitoring.editor` includes `serviceusage.services.enable`.** So
the deploy identity *can* enable APIs, even though it holds only
`serviceUsageConsumer` and the split was designed on the basis that it could
not. Verify:

```bash
gcloud iam roles describe roles/monitoring.editor --format='value(includedPermissions)' | tr ';' '\n' | grep serviceusage
```

**Latent, not exercised.** Terraform has no `google_project_service`
resource, so nothing in a deploy uses it — the capability is a property of
the *role*, not of anything the code does. But "Terraform cannot enable APIs"
is stated elsewhere as a property of the role set, and that is currently
overstated.

**The narrower replacement** is `roles/monitoring.alertPolicyEditor` +
`roles/monitoring.notificationChannelEditor`, which together cover the six
alert policies and one notification channel that Terraform actually creates.
Tracked as [OPEN-ITEMS: `monitoring.editor`](OPEN-ITEMS.md#monitoring-editor). Worth
raising directly: the request was that the deploy principal not hold
`serviceUsageAdmin`, and it does not — but an equivalent capability arrived
through a different door.

**2. `roles/run.admin` is broader than "administer this resource"**, as
described [above](#run-admin). Held by a service account, with a documented
but untested fallback.

---

## Runtime identities and the data boundary {#runtime}

Six service accounts, one per job, each scoped to its own inputs and
outputs. The scraper has no business holding the Snowflake secret; the
Lightcast job has no business writing the scrape cache.

| Identity | Project-level grants | Resource-scoped |
|---|---|---|
| `lightcast` | `bigquery.jobUser`, `logging.logWriter`, `monitoring.metricWriter` | The Snowflake secret, its own raw-bucket prefix, `owc_staging` + `owc_marts` |
| `enrollment` | `bigquery.jobUser`, `logging.logWriter`, `monitoring.metricWriter` | Its own state bucket and raw prefix, `owc_staging` + `owc_marts` |
| `scheduler` | **none** | `run.developer` on the two jobs specifically |
| `build` | `logging.logWriter`, `storage.objectViewer` | The image registry |
| `freshness` | `bigquery.jobUser` | `owc_ops` |
| `powerbi` | `bigquery.jobUser`, `bigquery.readSessionUser` | `dataViewer` on `owc_marts` **only** |

**The scheduler holds no project-level role at all.** Its grant is
`run.developer` on the two jobs, and it is `run.developer` rather than
`run.invoker` because the schedulers post an *overrides* body, which needs
`run.jobs.runWithOverrides` — a permission `run.invoker` does not carry.

**`bigquery.readSessionUser` on `powerbi` is project-scoped by necessity**,
not by choice: `bigquery.readsessions.create` has no dataset-level
equivalent. It does not widen the read surface — opening a read session
still requires `bigquery.tables.getData` on the table, which this account
holds on `owc_marts` alone. `owc_staging` (unvalidated data) and `owc_ops`
(the run manifest) stay unreachable, and `verify-separation` asserts both on
every deploy.

**Neither bucket is public.** Both set
`public_access_prevention = "enforced"`, and `prevent_destroy` is set on the
raw bucket, the enrollment state bucket and `owc_marts`.

---

## The one documented exception: the PowerBI key {#powerbi-key}

**A service-account JSON key exists, and it is the only one.**

The PowerBI BigQuery connector authenticates as a Google organizational
account or via a service-account JSON key. There is no third option, and
per-user OAuth breaks scheduled refresh the day that person leaves. The
decision, its scope and the events that force a replacement are in
[ADR-006](architecture.md#adr-006-one-tightly-scoped-json-key-for-powerbi).

What makes it defensible is the scope, not the lifetime. The key belongs to
an identity that can read one dataset of published data and **cannot** write
anything, reach the raw bucket, or see `owc_ops` or `owc_staging` — and
`make verify-separation` asserts each of those on every deploy.

**It is deliberately not rotated on a schedule.** An earlier version of this
decision said "rotate annually"; nothing in this repo can enforce that, and a
control written down but never performed is worse than one never claimed.
`make powerbi-key ENV=<env>` performs the replacement safely when one of the
documented triggers occurs.

**If the organization enforces
`constraints/iam.disableServiceAccountKeyCreation`**, ADR-006's "there is no
third option" does not hold, and the remaining choices are an org-policy
exception scoped to that one account, a Google organizational account signed
in to the data source, or federating Entra ID through Workload Identity
Federation. Check before assuming:

```bash
cd ~/owc && eval "$(make -s env-exports ENV=prod)"
```

```bash
gcloud resource-manager org-policies describe constraints/iam.disableServiceAccountKeyCreation --project $PROJECT --effective
```

---

## The open question for production {#prod-question}

**Everything above is verified on `owc-dpar-d`. None of it is yet true of
`owc-dpar-p`, which has not been built.**

**Dev is strong evidence, and worth stating precisely.** Measured from
`owc-dpar-d`'s IAM policy on 2026-09-30, `sa-owc-dpar-d-deploy-1` holds all
eleven roles and **nothing else**, and every one of the six forbidden roles
is absent from it. Both pipelines deploy and run on exactly that set. The
claim is therefore not "about eleven roles" but "these eleven, no more,
demonstrably run the platform."

Five of the six forbidden roles appear against no principal in that
project's policy, including `projectIamAdmin` and `serviceAccountAdmin` —
with the inheritance caveat [above](#verification). The
exception is `roles/serviceusage.serviceUsageAdmin`, still held by two human
accounts that predate the split —
[OPEN-ITEMS: what dev's policy shows](OPEN-ITEMS.md#dev-baseline) has the detail and the
reasoning. **Prod should never create that situation**, which costs nothing
to get right on a project being built from nothing.

What dev does not prove is that the set is *obtainable* on a production
project, where the review may be stricter and may be done by someone else.

Only `roles/run.admin` has a fallback. **The other ten do not.** If a
production review refuses `roles/bigquery.admin` or
`roles/secretmanager.admin`, the deploy stops and the design has to be
reopened rather than worked around.

**So the ask is to review the whole list in one pass, before the one-time
step runs:**

```bash
make gcloud-admin-dry-run ENV=prod
```

Tracked as [OPEN-ITEMS: agree the prod role set](OPEN-ITEMS.md#prod-role-set). Deciding it in
advance costs an email. Discovering it mid-deploy costs a second round-trip
with a half-built project in between.

The platform constraints already known to apply, each hit on a real project,
are catalogued in
[`gcp-reference.md`](gcp-reference.md#omes-constraints).
