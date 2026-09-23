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
