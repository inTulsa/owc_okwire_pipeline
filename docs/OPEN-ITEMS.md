# Open items

Everything here is genuinely unresolved. Each item names **who** can settle it
and **what it costs to leave it**, because an open item with neither is a
worry rather than a task.

Solved problems are not listed. If something is described here, it is still
true as of **2026-09-30**.

- [Before prod can be built](#before-prod)
  - [1. Agree the prod role set with the platform team](#prod-role-set)
  - [2. Create the deploy identity on `owc-dpar-p`](#deploy-identity)
  - [3. `snowflake_user` in prod is a placeholder](#snowflake-user)
  - [4. Pause dev's schedulers before prod goes live](#pause-dev)
  - [5. Terraform state hosting](#state-hosting)
- [Known gaps in what is deployed](#known-gaps)
  - [6. `monitoring.editor` lets the deploy identity enable APIs](#monitoring-editor)
  - [7. The scheduler-IAM fallback has never been executed](#scheduler-fallback)
  - [8. `make lock-check` is red](#lock-check)
- [Decisions that need someone outside this repo](#external-decisions)
  - [9. Fill in the quarterly and yearly dataset lists](#dataset-groups)
  - [10. Tell Lightcast before raising `parallelism` above 4](#parallelism)
  - [11. Confirm the Snowflake account is a true reader account](#reader-account)
  - [12. Confirm the Lightcast license permits this audience](#license-audience)
  - [13. Move the enrollment repo in, preserving history](#enrollment-history)
- [Also worth knowing](#also-worth-knowing)

---

## Before prod can be built {#before-prod}

## 1. Agree the prod role set with the platform team {#prod-role-set}

**Owner:** the OWC administrator, with the OMES platform team.

**The eleven roles the deploy account needs have only ever been granted on
`owc-dpar-d`.** Dev proves the set is *sufficient* and *exact* — measured on
2026-09-30, `sa-owc-dpar-d-deploy-1` holds all eleven and nothing else, and
deploys run end to end on them. That is the strongest form of the argument:
not "eleven roles are roughly right" but "these eleven, no more, demonstrably
run the platform."

It does not prove the set is *obtainable*, because a different reviewer on a
different project may draw the line somewhere else.

Only one of the eleven has a documented fallback. `roles/run.admin` is the
broad one, the setup script tries it, falls back to `roles/run.developer`
on refusal, and [`deploy.md`](deploy.md#run-admin-decision) covers what
changes. **The other ten have no fallback path** — if prod's review refuses
`roles/bigquery.admin` or `roles/secretmanager.admin`, the deploy stops and
there is no documented answer.

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

**Consequence:** the privileged step runs **once** per project. Discovering
mid-deploy that a role was refused means going back to the same reviewer a
second time, with a half-built project in between.

---

## 2. Create the deploy identity on `owc-dpar-p` {#deploy-identity}

**Owner:** an admin holding `serviceAccountAdmin` + `projectIamAdmin` +
`serviceUsageAdmin` on `owc-dpar-p`.

**`owc-dpar-p` has none of its seven service accounts.** Everything about
prod's identity model is still to be created, which is the good case: there
is no migration, and no human ever has to hold resource-admin roles there
even temporarily.

Run once, before anything else, after [item 1](#prod-role-set) is agreed:

```bash
make gcloud-admin ENV=prod OPERATOR=group:THE-GROUP@agency.ok.gov
```

**Ask for a group, not a person.** More than one person will deploy
eventually, and a group makes the next one a membership change rather than
another IAM request. It has to exist in the organization's directory first —
this repo cannot create it and does not try. Two traps and the test that
catches both are in [`deploy.md`](deploy.md#deployer-group).

### What dev's policy actually shows {#dev-baseline}

Read from `gcloud projects get-iam-policy owc-dpar-d` on **2026-09-30**.
This is the measured baseline, not an expectation.

**The deploy identity is exactly right.** `sa-owc-dpar-d-deploy-1` holds all
eleven required roles and **nothing else** — no extras, no drift. The model
works as designed, and dev is the evidence for it.

**Five of the six forbidden roles appear against no principal in the
project policy**, including `roles/resourcemanager.projectIamAdmin` and
`roles/iam.serviceAccountAdmin` — the two the platform team named first.
Read that as written: it is a statement about the project policy, and an
inherited grant would not appear in it. See
[the limits below](#audit-limits).

**One is not.** `roles/serviceusage.serviceUsageAdmin` is held by two human
accounts: the OWC administrator and the developer account. That is one of
the four roles `TF_PRINCIPAL_FORBIDDEN_ROLES` exists to keep off principals,
and it is the remaining gap between the design and the deployed reality.

Three human accounts also hold 10–12 project roles each — `storage.admin`,
`bigquery.admin`, `secretmanager.admin`, `cloudscheduler.admin`,
`artifactregistry.admin`, `monitoring.editor`, `logging.configWriter`,
`run.developer` and others. These predate the deploy identity.

**On dev, that is a decision rather than drift.** The OWC administrator owns
this platform and will maintain it with the OMES platform team; administering
it is that person's role. The developer account is scoped to dev and keeps
its access until prod is running and handover is complete.

**On prod it should never be created.** The property the split exists to
achieve is free to establish on `owc-dpar-p` from its first day and expensive
to retrofit. Prod's policy should show the deploy identity holding the eleven,
named people holding `tokenCreator` on it, and nothing else.

### Two limits of the check, which matter when quoting it {#audit-limits}

`make iam-check ENV=dev STRICT=1` **passes on dev today**, because it audits
`TF_PRINCIPAL` — the deploy service account — and that account is clean. It
says nothing about the two human accounts above.

To audit a person, name them, one at a time:

```bash
make iam-check ENV=dev STRICT=1 TF_PRINCIPAL=user:someone@agency.ok.gov
```

And it reads the **project** policy only, so a role inherited from the
organization or folder does not appear. That is not hypothetical here: the
administrator who ran the one-time setup successfully wrote the project IAM
policy while holding no project-level `projectIamAdmin` or `owner`. Their
authority to do so must therefore come from above the project, where nothing
in this repo can see it.

For a whole-project statement, read the policy directly and keep the output:

```bash
gcloud projects get-iam-policy owc-dpar-d --format=yaml
```

**Consequence:** until the privileged step runs on prod, prod cannot be
deployed at all. Separately, until `serviceUsageAdmin` comes off those two
accounts, the no-admin-roles property is true of the deploy identity and not
yet true of the project.

---

## 3. `snowflake_user` in prod is a placeholder {#snowflake-user}

**Owner:** whoever holds the Lightcast reader-account credentials.

`infra/terraform/envs/prod/terraform.tfvars` ships `REPLACE_ME@…`. The plan
rejects it on purpose rather than building a pipeline that cannot
authenticate.

The password is separate and never goes in Terraform — it is added to Secret
Manager by hand during [`deploy.md` step 7](deploy.md#stand-it-up).

**Consequence:** prod's first `make up` stops here. Cheap to fix, listed so
it is not a surprise.

---

## 4. Pause dev's schedulers before prod goes live {#pause-dev}

**Owner:** whoever runs the prod release.

`infra/terraform/envs/dev/terraform.tfvars` has `schedulers_paused = false`.
That was set deliberately so the scheduled path could be exercised on dev,
and it is commented as temporary. **That window closes the moment prod is
live.**

Both environments read the same [`pipelines.yml`](../pipelines.yml), so they
fire the same 35 Snowflake queries at the same minute — twice, against
Lightcast's warehouse, contending for `TULSA_FOR_YOU_WH`.

Do it **before** prod's first apply. Set `schedulers_paused = true` in dev's
tfvars, then:

```bash
make tf-apply ENV=dev
```

Then confirm, from a shell that knows which project it is pointed at:

```bash
cd ~/owc && eval "$(make -s env-exports ENV=dev)"
```

```bash
gcloud scheduler jobs list --location $REGION --project $PROJECT --format="table(name,state,schedule)"
```

Both dev schedulers should report `PAUSED`.

**The environments are deliberately not coupled.** A prod deploy does not
read dev's configuration and must not start doing so — they are separate
projects, and a checkout pointed at a test project would make any such check
meaningless. What exists instead:

- **A notice on every apply**, from that environment's own tfvars.
  `make tf-apply ENV=dev` states that the dev schedulers are unpaused for as
  long as they are. No other environment is consulted.
- **An opt-in cross-check**, off by default, for exactly this moment:

  ```bash
  make tf-apply ENV=prod CHECK_OTHER_ENV=dev
  ```

  Naming the other environment is the whole interface. It refuses if that
  environment's schedulers are live, and otherwise says so and continues.

**Consequence:** nothing breaks visibly. It doubles a bill somebody else
receives, which is the kind of mistake that survives for months.

---

## 5. Terraform state hosting {#state-hosting}

**Owner:** the OMES platform team.

**Raised and never resolved** — *"we can hook up your instance with the
state."* Today both state buckets live in their own project, created by
`01-admin-identities.sh` rather than by Terraform, so a `terraform destroy`
cannot take the state with it.

**If they will host it:** they add `--no-state-bucket` to the setup script,
tell you the bucket name, and you set it in **both** `terraform.tfvars` and
`backend.tf` before the first apply, or pass `STATE_BUCKET=` on every
command.

**Consequence:** nothing breaks. It is materially cheaper to answer before
prod's first apply than to migrate state afterwards.

---

## Known gaps in what is deployed {#known-gaps}

## 6. `monitoring.editor` lets the deploy identity enable APIs {#monitoring-editor}

**Owner:** an admin, plus a verification pass. Not urgent.

`roles/monitoring.editor` includes `serviceusage.services.enable`. So the
deploy identity can turn APIs on, even though it holds only
`serviceusage.serviceUsageConsumer` and the split was designed on the basis
that it could not. Confirmed on `owc-dpar-d`:

```bash
gcloud iam roles describe roles/monitoring.editor --format='value(includedPermissions)' | tr ';' '\n' | grep serviceusage
```

**Latent, not used.** Terraform has no `google_project_service` resource, so
nothing in a deploy exercises it. But "Terraform cannot enable APIs" is
stated in [`deploy.md`](deploy.md) and
[`gcp-reference.md`](gcp-reference.md) as a property of the *role set*, and
right now it is a property of the *code* only.

**The fix is narrower roles.** Terraform creates six
`google_monitoring_alert_policy` and one
`google_monitoring_notification_channel` — nothing else in monitoring. So

```
roles/monitoring.alertPolicyEditor
roles/monitoring.notificationChannelEditor
```

should replace `roles/monitoring.editor` in `TF_PRINCIPAL_ROLES`. Verify
both carry what the module needs and that neither carries
`serviceusage.services.enable` before swapping, then re-run
`make gcloud-admin` and remove the old binding.

**Consequence:** a reviewer who checks the claim finds it overstated. Worth
raising proactively: the ask was for the deploy principal not to hold
`serviceUsageAdmin`, and it does not — but the capability arrived through a
different door. Fold this into [item 1](#prod-role-set) rather than raising
it twice.

---

## 7. The scheduler-IAM fallback has never been executed {#scheduler-fallback}

**Owner:** whoever is willing to spend a throwaway project on it.

`scheduler_job_iam_in_terraform = false` is the branch that runs when an
admin refuses `roles/run.admin`. It gives a Terraform resource `count = 0`
and moves the scheduler's `run.invoker` binding out to
`make scheduler-grant`, run by an admin after the first deploy.

**That path has never run.** Dev was granted `run.admin`, so the fallback is
untested code with documentation promising it works. The documentation now
says so — see [`deploy.md`](deploy.md#run-admin-decision) — but saying so is
not the same as testing it.

**Consequence:** if prod's review refuses `run.admin`, the fallback is
exercised for the first time on prod, where `schedulers_paused = false`
means a mistake surfaces as a 403 on the 1st of the month rather than at a
terminal. [Item 1](#prod-role-set) is how you find out early enough to test
it deliberately instead.

---

## 8. `make lock-check` is red {#lock-check}

**Owner:** whoever does the next dependency pass. **Not during a release.**

Five packages have drifted from `requirements.txt`:

```
boto3               1.43.99  →  1.43.103
botocore            1.43.99  →  1.43.103
google-api-core      2.38.0  →  2.39.0
google-auth          2.58.0  →  2.58.1
google-cloud-storage 3.14.1  →  3.15.0
```

`make lock` fixes it, and it changes what the next image installs — so it
needs its own build and its own smoke test.

**Consequence:** `make check` fails, which trains people to ignore a red
gate. Fix it deliberately, on its own commit, not folded into something
else.

---

## Decisions that need someone outside this repo {#external-decisions}

## 9. Fill in the quarterly and yearly dataset lists {#dataset-groups}

**Owner:** someone who knows Lightcast's actual refresh cycles per dataset.

**Where:** [`pipelines.yml`](../pipelines.yml) —
`lightcast.groups.quarterly.datasets` and `.yearly.datasets`, both `[]`
today.

**Current state:** all 35 datasets run monthly. That is never *wrong* — only
more often than necessary, which spends Lightcast warehouse credits
re-querying data that has not changed.

**When you fill them in,** one `terraform apply` moves those datasets out of
the monthly group, adjusts the monthly task count, and creates the
quarterly/yearly Cloud Scheduler jobs — which do not exist while the lists
are empty. Verified working:

```
monthly 28 / quarterly 3 / yearly 4   →  three schedulers, 35 datasets, no overlap
```

**Consequence:** a recurring cost on somebody else's warehouse, for no
benefit.

---

## 10. Tell Lightcast before raising `parallelism` above 4 {#parallelism}

**Owner:** a conversation with Lightcast, before the change.

**Where:** `parallelism = 4` in each env's `main.tf`.

**Why:** reader-account warehouse credits bill to **Lightcast, not us**. The
original pipeline ran one query at a time. Going to 8 is an 8× concurrency
increase on someone else's bill, and it could trip a provider-side resource
monitor that silently suspends `TULSA_FOR_YOU_WH`.

Also note `MAX_CONCURRENCY_LEVEL` defaults to 8 statements per warehouse
cluster, so fanning past ~8 just queues while Cloud Run bills for blocked
tasks. `STATEMENT_QUEUED_TIMEOUT_IN_SECONDS` is set to 600 so a queued query
fails fast rather than holding a paid task open.

**The 35-way fan-out has been exercised once.** All 35 datasets published
successfully on 2026-09-30 at `parallelism = 4`, started by Cloud Scheduler
— so the fan-out, the 30-minute task timeout and the in-memory filesystem
are no longer untested at scale. That is one run, at one parallelism, and it
is the only evidence there is.

**Consequence:** their warehouse, their credits, their resource monitor.

---

## 11. Confirm the Snowflake account is a true reader account {#reader-account}

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

## 12. Confirm the Lightcast license permits this audience {#license-audience}

**Owner:** whoever holds the Lightcast license agreement.

**PowerBI is now connected and serving a real audience**, which makes this
live rather than hypothetical. Confirm the license permits these derived
tables in a PowerBI report with the audience that actually has access to the
workspace.

**Current state:** GCP-side access is limited to the pipeline service
accounts plus `sa-<name_prefix>-powerbi-1`, read-only on `owc_marts` alone.
Nothing is public; both buckets have `public_access_prevention = "enforced"`.
The audience question is therefore entirely about who can open the PowerBI
workspace, which is not governed by anything in this repo.

**Consequence:** a licensing exposure that GCP IAM cannot see and this repo
cannot enforce.

---

## 13. Move the enrollment repo in, preserving history {#enrollment-history}

**Owner:** needs an ownership conversation with the script's author.

**Current state:** `primary_enrollment_data_script.py` was copied, not
imported, so its git history is not in this repo. The pristine copy is at
`tests/fixtures/primary_enrollment_data_script.original.py` and the
documentation came across to [`docs/enrollment/`](enrollment/).

**Recommended:** `git subtree add` or `git-filter-repo` rather than leaving
it a fresh copy, so the `.docx` documentation history survives.

**Consequence:** the change history of a 759-line file that encodes
somebody else's undocumented HTML and spreadsheet conventions lives in a
different repository.

---

## Also worth knowing {#also-worth-knowing}

**The PowerBI key is deliberately not rotated on a schedule.** What carries
the risk is its scope — read-only on `owc_marts` alone, asserted by
`make verify-separation` on every deploy — not its age. The events that
force a replacement, and the rotation sequence, are in
[ADR-006](architecture.md#adr-006-one-tightly-scoped-json-key-for-powerbi).

**Cloud NAT is not built.** If `oklahoma.gov` ever blocks Cloud Run's shared
egress ranges, the fix is Cloud NAT with a static IP. Not built now, noted
here so it is not a mystery at 2am.

**The hardcoded year literals are still hardcoded.** By design — rewriting
working queries was out of scope. Alert 5 is the smoke detector; the
procedure for when it fires is
[in the runbook](runbook.md#stale-year-literals).

**The runtime grants were verified clean on 2026-09-30.** All six runtime
identities on `owc-dpar-d` hold exactly the project-level roles
`RUNTIME_PROJECT_GRANTS` specifies — no missing grants, no extras, including
the `bigquery.readSessionUser` that was once added by hand. A drift report
from `iam-check` after this date is a real finding, not leftover history.

**PowerBI runs Import, not DirectQuery**, on Premium capacity in the
Government cloud. That settles the clustering question in
[ADR-002](architecture.md#adr-002-marts-tables-are-unpartitioned-and-unclustered)
— Import copies the data into the semantic model, so BigQuery clustering
cannot affect how a slicer performs. It also means BigQuery sees one large
read per scheduled refresh rather than a scan per interaction, which is the
cheap side of that trade.
