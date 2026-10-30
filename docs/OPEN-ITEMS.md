# Open items

Everything here is genuinely unresolved. Each item names **who** can settle it
and **what it costs to leave it**, because an open item with neither is a
worry rather than a task.

Solved problems are not listed. If something is described here, it is still
true as of **2026-10-30**.

---

## Handoff status {#delivery-status}

**`owc-dpar-d` is live and verified. `owc-dpar-p` has not been built.**
Building it is the receiving team's first job, and it is also the first real
test of these documents. Their central claim is:

> Someone who was not present when `owc-dpar-d` was built can stand up
> `owc-dpar-p` from [`deploy.md`](deploy.md) alone.

`deploy.md` has been reconciled against everything that actually happened on
dev, but a procedure is verified by being followed, not by being reviewed.
**Build prod from `deploy.md` and keep notes.** A step that needed
improvising is a documentation defect, not operator skill: fix the document
in the same change.

### Before prod's first apply

| Item | Why it comes first |
|---|---|
| [Agree the prod role set](#prod-role-set) | The privileged step runs once. A refused role found mid-deploy means a second trip to the same reviewer |
| [Terraform state hosting](#state-hosting) | Cheap to answer before the first apply, a migration after it |

### At handoff

| Item | Why |
|---|---|
| [Remove the developer's access](#offboard-developer) | The developer's account still holds resource-admin roles on dev |

### What is verified on dev, as of 2026-10-30

- `make check` passes: lint, types, lock, docs, shell, names, validate, unit
  tests.
- Terraform plans clean against `owc-dpar-d`; `make verify-separation`
  passes.
- Both pipelines have run end to end on dev, scheduler-started, with all 35
  datasets published (2026-09-30). Dev runs the image built from the
  2026-10-30 handoff commit.
- The IAM claims are measured against `owc-dpar-d`'s actual policy rather
  than asserted — see [what dev's policy shows](#dev-baseline).
- Dev's schedulers are paused and its alerts go to the OWC address prod uses.

---

## Before prod's first apply {#before-prod}

## 1. Agree the prod role set with the platform team {#prod-role-set}

**Owner:** the OWC administrator, with the OMES platform team.

**The eleven roles the deploy account needs have only ever been granted on
`owc-dpar-d`.** Dev proves the set is *sufficient* and *exact* —
`sa-owc-dpar-d-deploy-1` holds all eleven and nothing else, and deploys run
end to end on them. That is the strongest form of the argument: not "eleven
roles are roughly right" but "these eleven, no more, demonstrably run the
platform."

It does not prove the set is *obtainable*, because a different reviewer on a
different project may draw the line somewhere else.

**Settle it before the privileged step runs**, not during it:

```bash
make gcloud-admin-dry-run ENV=prod
```

That output is every command, shell-quoted, with nothing inferred. Send it
for review and get agreement on the whole list in one pass. The roles and
what each one is for are in
[`deploy.md`](deploy.md#the-roles-before-and-after); the narrowing analysis
a reviewer is most likely to ask for is in
[`security-model.md`](security-model.md).

**Then run it once, naming a group rather than a person** —
[`deploy.md` step 5](deploy.md#deployer-group) has the two traps and the test
that catches both:

```bash
make gcloud-admin ENV=prod OPERATOR=group:THE-GROUP@agency.ok.gov
```

`owc-dpar-p` has none of its seven service accounts yet, which is the good
case: no human ever has to hold resource-admin roles there, even
temporarily. Prod's policy should show the deploy identity holding the
eleven, the deployer group holding `tokenCreator` on it, and nothing else.

**Consequence:** the privileged step runs **once** per project. Discovering
mid-deploy that a role was refused means going back to the same reviewer a
second time, with a half-built project in between.

### A reviewer may object to `monitoring.editor` {#monitoring-editor}

`roles/monitoring.editor` includes `serviceusage.services.enable`, so the deploy identity could turn an API on
even though it holds only `serviceUsageConsumer`. Nothing uses it — no
Terraform resource enables an API — but "the deploy identity cannot enable
APIs" is a property of the code, not of the role set. If the reviewer
objects, `roles/monitoring.alertPolicyEditor` plus
`roles/monitoring.notificationChannelEditor` cover what Terraform creates;
the swap is untested, so plan against dev before relying on it.

### If `run.admin` is refused {#scheduler-fallback}

The setup script falls back to `run.developer` and the scheduler's
`run.invoker` binding moves to `make scheduler-grant`, run by an admin after
the first deploy. That path has never run, because dev was granted
`run.admin`. [`deploy.md`](deploy.md#run-admin-decision) has the procedure.
If the review refuses it, exercise the fallback on dev first rather than
discovering it as a 403 on prod's first scheduled run.

### What dev's policy shows {#dev-baseline}

Read from `gcloud projects get-iam-policy owc-dpar-d`. This is the measured
baseline, not an expectation.

**The deploy identity is exactly right.** `sa-owc-dpar-d-deploy-1` holds all
eleven required roles and **nothing else**. All six runtime identities hold
exactly the roles `RUNTIME_PROJECT_GRANTS` specifies.

**Five of the six forbidden roles appear against no principal in the
project policy**, including `roles/resourcemanager.projectIamAdmin` and
`roles/iam.serviceAccountAdmin` — the two the platform team named first.
That is a statement about the project policy; an inherited grant would not
appear in it.

**Human accounts on dev predate the deploy identity.** The OWC
administrator holds resource-admin roles, plus
`roles/serviceusage.serviceUsageAdmin`, the sixth forbidden role. That is a
decision rather than drift: administering this platform is that person's
role. The developer's account holds the same set until
[it is removed](#offboard-developer).

**On prod none of that should be created.** The separation is free to
establish on `owc-dpar-p` from its first day and expensive to retrofit.

**Two limits when quoting the check.** `make iam-check ENV=dev STRICT=1`
audits the deploy service account, not people; to audit a person, name them
with `TF_PRINCIPAL=user:someone@agency.ok.gov`. And it reads the **project**
policy only — the administrator who ran the one-time setup wrote the project
IAM policy while holding no project-level `projectIamAdmin`, so their
authority comes from above the project, where nothing in this repo can see
it. For a whole-project statement, keep the output of:

```bash
gcloud projects get-iam-policy owc-dpar-d --format=yaml
```

---

## 2. Terraform state hosting {#state-hosting}

**Owner:** the OMES platform team.

**Raised and never resolved** — *"we can hook up your instance with the
state."* Today each project's state bucket is created by the one-time setup
rather than by Terraform, so a `terraform destroy` cannot take the state
with it.

**If they will host it:** they add `--no-state-bucket` to the setup script
and tell you the bucket name. Set it as the `STATE_BUCKET` default in the
`Makefile`, or pass `STATE_BUCKET=` on every command, before prod's first
apply.

**Consequence:** nothing breaks. It is materially cheaper to answer before
prod's first apply than to migrate state afterwards.

---

## At handoff {#at-handoff}

## 3. Remove the developer's access {#offboard-developer}

**Owner:** an admin who can write the `owc-dpar-d` project IAM policy. The
developer cannot remove their own bindings — no human holds
`projectIamAdmin` on this project, which is the design working.

The developer's account holds about ten resource-admin roles on `owc-dpar-d`
from before the deploy identity existed, plus `serviceUsageAdmin`, plus
`tokenCreator` on the deploy account. None of it is needed once the work is
handed over. Run these as that admin, not impersonating the deploy account:

```bash
export PROJECT=owc-dpar-d
```

List what it holds:

```bash
gcloud projects get-iam-policy $PROJECT --flatten=bindings --filter="bindings.members:user:THE-DEVELOPER@agency.ok.gov" --format="value(bindings.role)"
```

Remove each role it prints:

```bash
gcloud projects remove-iam-policy-binding $PROJECT --member user:THE-DEVELOPER@agency.ok.gov --role THE-ROLE --condition=None
```

And the impersonation grant:

```bash
gcloud iam service-accounts remove-iam-policy-binding sa-$PROJECT-deploy-1@$PROJECT.iam.gserviceaccount.com --project $PROJECT --member user:THE-DEVELOPER@agency.ok.gov --role roles/iam.serviceAccountTokenCreator
```

Repeat for any other account the developer used. Done when the list
command above prints nothing.

**Replace the PowerBI key if the developer ever held a copy.** That is one
of the events
[ADR-006](architecture.md#adr-006-one-tightly-scoped-json-key-for-powerbi)
names: mint a new one with `make powerbi-key`, put it in the workspace,
confirm a refresh, then delete the old key.

**Safe to do immediately.** Deploys run as `sa-owc-dpar-d-deploy-1`, the
APIs are already enabled, and nothing scheduled or in the runbook needs the
developer's account.

**Consequence of leaving it:** a departed contributor keeps admin rights on
the dev project, and the no-human-admin property the platform team asked for
stays untrue of dev.

---

## Decisions that need someone outside this repo {#external-decisions}

## 4. Confirm the Snowflake account is a true reader account {#reader-account}

**Owner:** Lightcast, or one query.

**Why it matters:** Snowflake's password deprecation explicitly exempts
reader accounts.
[ADR-004](architecture.md#adr-004-snowflake-password-auth-is-kept) depends
on that exemption. If `EMSIBG-READER_TULSA_FOR_YOU` is a *regular* account
holding a share rather than a reader account, the exemption lapses and
migrating to key-pair auth becomes time-sensitive.

**How to check:**

```sql
SELECT CURRENT_ACCOUNT(), CURRENT_ORGANIZATION_NAME();
```

Or just ask Lightcast.

**Consequence:** if it is not a reader account, key-pair auth is a change to
`SnowflakeSettings` and `snowflake.py` only — the connection is already
isolated behind `connect()`. The risk is the deadline, not the work.

---

## 5. Confirm the Lightcast license permits this audience {#license-audience}

**Owner:** whoever holds the Lightcast license agreement.

**PowerBI is connected and serving a real audience.** Confirm the license
permits these derived tables in a PowerBI report with the audience that
actually has access to the workspace.

GCP-side access is limited to the pipeline service accounts plus
`sa-<name_prefix>-powerbi-1`, read-only on `owc_marts` alone. Nothing is
public. The audience question is therefore entirely about who can open the
PowerBI workspace, which nothing in this repo governs.

**Consequence:** a licensing exposure that GCP IAM cannot see and this repo
cannot enforce.

---

## Also worth knowing {#also-worth-knowing}

### Talk to Lightcast before raising `parallelism` above 4 {#parallelism}

It is set in each env's `main.tf`. Reader-account warehouse credits bill to
**Lightcast**, the original pipeline ran one query at a time, and a
provider-side resource monitor could silently suspend `TULSA_FOR_YOU_WH`.
Past about 8 it only queues anyway — `MAX_CONCURRENCY_LEVEL` defaults to 8
statements per cluster — while Cloud Run bills for the blocked tasks.

### All 35 datasets run monthly

The quarterly and yearly groups in
[`pipelines.yml`](../pipelines.yml) are empty. That is never wrong, only more
often than necessary; naming a dataset there and applying moves it, and
creates that group's scheduler.

### Cloud NAT is not built

If `oklahoma.gov` ever blocks Cloud Run's shared
egress ranges, the fix is Cloud NAT with a static IP.
