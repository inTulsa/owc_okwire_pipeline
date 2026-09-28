# Open items

Decisions and confirmations that need a human, carried over from the design.
Each one has a specific owner-type and a consequence for leaving it.

---

## 1. Fill in the quarterly and yearly dataset lists

**Where:** [`pipelines.yml`](../pipelines.yml) —
`lightcast.groups.quarterly.datasets` and `.yearly.datasets`, both `[]` today.

**Needs:** knowledge of Lightcast's actual refresh cycles per dataset.

**Current state:** all 35 datasets run monthly. That is never *wrong* — only
more often than necessary, which costs Lightcast warehouse credits for
querying data that has not changed.

**When you fill them in,** one `terraform apply` moves those datasets out of
the monthly group, adjusts the monthly task count, and creates the
quarterly/yearly Cloud Scheduler jobs — which do not exist while the lists are
empty. Verified working:

```
monthly 28 / quarterly 3 / yearly 4   →  three schedulers, 35 datasets, no overlap
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

## 7. Create the deploy identity on each project {#deploy-identity}

**Blocks prod, and dev is running without it.** This is no longer a design
question — the model is in the repo and
[documented](deploy.md#deploy-identity). What is left is running it.

Resource-admin roles belong to `sa-<prefix>-deploy-1`, which nobody logs in
as. A named person gets `roles/iam.serviceAccountTokenCreator` on that one
account and impersonates it to deploy.

### `owc-dpar-d` — set up under the old model, needs migrating

An admin runs, from an up-to-date clone:

```bash
make gcloud-admin ENV=dev OPERATOR=user:THE-PERSON@agency.ok.gov
```

Idempotent: it skips what exists and adds the deploy account, its roles, its
`actAs` bindings, and the operator's `tokenCreator`. Then the operator
confirms with `make deploy-identity ENV=dev`.

**Afterwards, the old grants should be removed** — until they are, the human
account still holds eleven resource-admin roles and the migration has added
a path rather than replaced one. `make iam-check ENV=dev STRICT=1` names what
is still attached, and it is the receipt to send OMES.

### `owc-dpar-p` — nothing exists yet, so get it right first time

The same command with `ENV=prod`, run once, before anything else. No
migration and no human ever holds the roles.

### Why a service account rather than a person

- **No human holds an admin-level role**, which is OMES's stated rule.
- **Actions stay attributable** — an impersonated call records both the
  service account and the person who minted the token.
- **Revoking is one binding**, not eleven roles and five `actAs` grants.

### The one thing to raise on the call

Ten of the eleven roles administer a single resource type. The eleventh,
`roles/run.admin`, is broader, and an organization may refuse it. **Nobody
needs to decide in advance:** the setup script tries it, falls back to
`roles/run.developer` if refused, prints which way it went, and prints the
two follow-up commands the fallback needs. `--no-run-admin` skips the
attempt for an admin who already knows the answer.

The full trade-off is in
[deploy.md](deploy.md#run-admin-decision). In short: `run.admin` means the
deploy is entirely self-service; `run.developer` means an admin comes back
once per environment, after the first deploy, to run two commands — and
until they do, every scheduled run 403s silently.

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

## 9. A full lightcast sync has never been run {#first-full-sync}

`make smoke` publishes `dim_area` only — 78 rows, unlimited, so it genuinely
publishes without paying for a full extract. Every other lightcast dataset
has been parse-validated (`make validate`, and `LIMIT 0` in the live
integration test) and never actually run. `owc_marts` holds `dim_area` and
nothing else from lightcast.

Three things follow, and the first two are why this is short rather than a
cleanup task:

- **The SQL consolidation orphaned nothing.** The six datasets it removed
  had never published, so there are no stale tables to drop. `dim_area` was
  not one of the files it changed.
- **The quality gate will not block the first real run.** `row_count_drift`
  compares against the previous successful run and 34 of the 35 datasets
  have none, so the check is skipped rather than failed. The first full sync
  *is* the baseline it will compare against afterwards.
- **The 35-way fan-out is untested at scale.** Parallelism 4 against
  Lightcast's warehouse, the 30-minute task timeout and the in-memory
  filesystem have been exercised by one small dimension table. Watch the
  first full run instead of scheduling it and walking away.

Do it in dev, deliberately. It bills Lightcast either way, so it is better
spent finding out somewhere a failure costs nothing else:

```bash
cd ~/owc && eval "$(make -s env-exports ENV=dev)" && echo "$PROJECT $PREFIX $REGION"
```

```bash
gcloud run jobs execute cr-$PREFIX-lightcast-1 --region $REGION --project $PROJECT --args="run,lightcast,--group,monthly" --tasks=35 --wait
```

Then read the manifest — every dataset should be `success`:

```bash
bq query --project_id=$PROJECT --use_legacy_sql=false --format=pretty 'SELECT status, COUNT(*) AS n FROM `owc_ops.pipeline_runs` WHERE pipeline = "lightcast" GROUP BY status'
```

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
