# Open items

Decisions and confirmations that need a human, carried over from the design.
Each one has a specific owner-type and a consequence for leaving it.

---

## 1. Fill in the quarterly and yearly dataset lists

**Where:** [`pipelines.yml`](../pipelines.yml) —
`lightcast.groups.quarterly.datasets` and `.yearly.datasets`, both `[]` today.

**Needs:** knowledge of Lightcast's actual refresh cycles per dataset.

**Current state:** all 41 datasets run monthly. That is never *wrong* — only
more often than necessary, which costs Lightcast warehouse credits for
querying data that has not changed.

**When you fill them in,** one `terraform apply` moves those datasets out of
the monthly group, adjusts the monthly task count, and creates the
quarterly/yearly Cloud Scheduler jobs — which do not exist while the lists are
empty. Verified working:

```
monthly 34 / quarterly 3 / yearly 4   →  three schedulers, 41 datasets, no overlap
```

---

## 2. Move the enrollment repo in, preserving history

**Current state:** `primary_enrollment_data_script.py` was copied, not
imported, so its git history is not in this repo. The pristine copy is at
`tests/fixtures/primary_enrollment_data_script.original.py` and the docs came
across to `docs/enrollment/`.

**Recommended:** `git subtree add` or `git-filter-repo` rather than leaving it
a fresh copy, so the `.docx` documentation history survives. Needs an
ownership conversation with the script's author first.

**Consequence of leaving it:** the change history of a 759-line file that
encodes somebody else's undocumented HTML and spreadsheet conventions lives in
a different repository.

---

## 3. Confirm `EMSIBG-READER_TULSA_FOR_YOU` is a true reader account

**Why it matters:** Snowflake's password deprecation explicitly exempts reader
accounts. [ADR-004](architecture.md#adr-004-snowflake-password-auth-is-kept)
depends on that exemption. If this is a *regular* account holding a share
rather than a reader account, the exemption lapses and migrating to key-pair
auth becomes time-sensitive.

**How to check:**

```sql
SELECT CURRENT_ACCOUNT(), CURRENT_ORGANIZATION_NAME();
```

Or just ask Lightcast.

**If it is not a reader account:** key-pair auth is a change to
`SnowflakeSettings` and `snowflake.py` only — the connection is already
isolated behind `connect()`.

---

## 4. Tell Lightcast before raising `parallelism` above 4

**Where:** `parallelism = 4` in each env's `main.tf`.

**Why:** reader-account warehouse credits bill to **Lightcast, not us**. The
original pipeline ran one query at a time. Going to 8 is an 8× concurrency
increase on someone else's bill, and it could trip a provider-side resource
monitor that silently suspends `TULSA_FOR_YOU_WH`.

Also note `MAX_CONCURRENCY_LEVEL` defaults to 8 statements per warehouse
cluster, so fanning past ~8 just queues while Cloud Run bills for blocked
tasks. `STATEMENT_QUEUED_TIMEOUT_IN_SECONDS` is set to 600 so a queued query
fails fast rather than holding a paid task open.

**Their warehouse, their credits, their resource monitor.**

---

## 5. Decide the PowerBI mode and licensing — before the marts layout is final

**This one has a deadline**, because it determines whether
[ADR-002](architecture.md#adr-002-marts-tables-are-unpartitioned-and-unclustered)
stays right.

| Mode | Implication |
|---|---|
| **Import on Pro** | A semantic model caps at **1 GB compressed**. The fact tables may not fit. |
| **Import on PPU** | 100 GB cap. Clustering becomes irrelevant — the data is copied into the model. |
| **DirectQuery** | Bills a BigQuery scan **per slicer click**. Needs a custom daily query quota (alert 9) and makes clustering matter a lot. |

**Also:** incremental refresh wants a datetime column, not a bare `YEAR`
integer. Adding one **would touch the Lightcast SQL**, which is why this is
better known now than after go-live.

Clustering prunes on a **left prefix** only, so column order has to match what
PowerBI actually filters on. That is unknowable until this is settled, which is
why nothing is clustered yet.

---

## 6. Confirm the Lightcast license permits this audience

**Before** the raw bucket or `owc_marts` get IAM wider than the pipeline
service accounts, confirm the license permits these derived tables in a
PowerBI report with the intended audience.

**Current state:** access is limited to the pipeline service accounts plus
`sa-<name_prefix>-powerbi-1` read-only on `owc_marts` only. Nothing is public; both buckets
have `public_access_prevention = "enforced"`.

---

## 7. The deploy identity should be a service account, not a person {#deploy-identity}

**This one blocks prod.** Settle it before the privileged step runs on
`owc-dpar-p`, so that project is set up once, correctly.

**Where:** [`names.sh`](../infra/gcloud/names.sh) (`TF_PRINCIPAL_ROLES`),
`01-admin-identities.sh`, `04-standalone.sh`, `00-access-check.sh`,
`02-verify-admin.sh`, and `TF_PRINCIPAL` in the [`Makefile`](../Makefile).

**The problem:** the one-time setup grants a deploy principal eleven
resource-admin roles plus `actAs` on five service accounts, and defaults that
principal to *whichever gcloud account is active when the script runs* — so an
admin running it from their own shell grants themselves. OMES has separately
said the deploy operator must not hold admin-level roles at all. Neither a
person's account nor the admin's is a correct answer, so the current design
has none.

**Recommended:** an account nobody logs in as.

```
sa-<prefix>-deploy-1@<project>.iam.gserviceaccount.com
```

- It holds the eleven resource-admin roles and `actAs` on the five runtime
  accounts. No human holds any of it.
- Whoever deploys is granted `roles/iam.serviceAccountTokenCreator` on **that
  one account** — auditable, revocable, and not an admin role.
- Terraform impersonates it with `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`, gcloud
  with `--impersonate-service-account`.

**Work it implies:** `names.sh` gains the account and decides where its roles
live; the two setup scripts create it and stop granting anything to a user
account; `TF_PRINCIPAL` becomes that account and the terraform targets export
the impersonation variable; `00-access-check.sh` tests the **impersonated**
identity rather than the caller's; `02-verify-admin.sh` asserts that no *user*
account holds the eleven roles, which is a stronger claim than it makes today.
The guard in `04-standalone.sh` that refuses when the principal equals the
caller can then be removed — the two can never be equal.

**Consequence of leaving it:** the operator cannot finish a deploy. Two
permissions in the normal path sit outside the eleven roles —
`run.jobs.setIamPolicy` (every `google_cloud_run_v2_job_iam_member`) and
`iam.serviceAccounts.actAs` (any Cloud Scheduler job update, which re-attaches
its service account). Both were hit on `owc-dpar-d`. The repo and the live
project then drift, because only an admin can reconcile them.

---

## 8. Ask OMES whether they will host the Terraform state bucket {#state-hosting}

**Raised and never resolved** — *"we can hook up your instance with the
state."* Today both state buckets live in their own project.

**If they will:** they add `--no-state-bucket` to the setup script, tell you
the bucket name, and you set it in **both** `terraform.tfvars` and
`backend.tf` before the first apply, or pass `STATE_BUCKET=` on every command.

**Consequence of leaving it:** nothing breaks. It is cheaper to answer before
prod's first apply than to migrate state afterwards.

---

## Also worth knowing

**The PowerBI JSON key exception.** The PowerBI BigQuery connector
authenticates as a Google organizational account or via a service-account JSON
key. There is no third option, and per-user OAuth breaks scheduled refresh the
day that person leaves. One tightly-scoped key for `sa-<name_prefix>-powerbi-1` is the
accepted answer — see
[ADR-006](architecture.md#adr-006-one-tightly-scoped-json-key-for-powerbi).
**Set a rotation reminder.**

**Cloud NAT is not built.** If `oklahoma.gov` ever blocks Cloud Run's shared
egress ranges, the fix is Cloud NAT with a static IP. Not built now, noted here
so it is not a mystery at 2am.

**The hardcoded year literals are still hardcoded.** By design — rewriting
working queries was out of scope. Alert 5 is the smoke detector; the procedure
for when it fires is
[in the runbook](runbook.md#stale-year-literals).
