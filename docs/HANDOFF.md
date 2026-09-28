# Handoff — open issues and what OMES has actually enforced

Written 2026-09-28, at the end of a long session standing `owc-dpar-d` up.
Read this first in a new session; it is the state of play, not a design doc.

- [Where things stand](#where-things-stand)
- [Open issue 1: the scheduler 403](#open-issue-1-the-scheduler-403)
- [Open issue 2: the deploy principal is a person](#open-issue-2-the-deploy-principal-is-a-person)
- [What OMES actually enforces](#what-omes-actually-enforces)
- [Failures so far, and what each one means](#failures-so-far-and-what-each-one-means)
- [Do these in order](#do-these-in-order)

---

## Where things stand

**`owc-dpar-d` (OMES dev) is deployed and the pipelines work.** Both ran end
to end and published: `dim_area` 78 rows, `enrollment_primary` ~1.4M, both
`success` in `owc_ops.pipeline_runs`. Datasets, buckets, registry, secret,
both Cloud Run jobs, both schedulers, the alert policies and the log metrics
all exist.

**One thing does not work: Cloud Scheduler cannot start the jobs.** Every
fire returns 403. See below.

**`owc-dpar-p` (OMES prod) has not been started.** Its six service accounts
do not exist. Two things need deciding before it can be: `snowflake_user` in
`envs/prod/terraform.tfvars` is still the `REPLACE_ME@` placeholder, which
the plan rejects on purpose, and prod runs schedulers **unpaused** with the
freshness check **enabled** — so the scheduler issue below is a prod blocker,
not a cosmetic one.

People and accounts:

| | |
|---|---|
| Deploy operator | `gtorianyk@agency.ok.gov` — **must not hold admin-level roles**, see issue 2 |
| OMES admin | `sswami@agency.ok.gov` — ran the privileged setup |
| Project number | `495483346183` (appears in service agent addresses) |

---

## Open issue 1: the scheduler 403

### The symptom

```text
status      PERMISSION_DENIED
debugInfo   URL_ERROR-ERROR_OTHER. Original HTTP response code number = 403
url         .../v1/namespaces/owc-dpar-d/jobs/cr-owc-dpar-d-lightcast-1:run
```

`make scheduler-debug ENV=dev` reports everything correct:

- `run.invoker` on both jobs, **exact** role+member binding match
- each scheduler sends oauth as `sa-owc-dpar-d-scheduler-1`
- `roles/iam.serviceAccountTokenCreator` on that account for
  `service-495483346183@gcp-sa-cloudscheduler.iam.gserviceaccount.com`,
  confirmed from the admin's own `get-iam-policy` output

A `debugInfo` of `Original HTTP response code number = 403` means the HTTP
call **was made** — so the token was minted and Cloud Run rejected it. The
problem is on the Cloud Run side, not the impersonation side.

### Leading hypothesis: the request body needs a different permission

`modules/pipeline/scheduler.tf` posts **overrides**:

```hcl
body = base64encode(jsonencode({
  overrides = {
    containerOverrides = [{ args = concat(["run", var.name], each.value.args) }]
    taskCount          = each.value.task_count
  }
}))
```

Running a Cloud Run job **with overrides** requires
`run.jobs.runWithOverrides`, which is a separate permission from
`run.jobs.run`. `roles/run.invoker` grants `run.jobs.run`. It does **not**
grant `runWithOverrides`.

`modules/pipeline/job.tf` asserts the opposite in a comment — *"roles/run.invoker
is correct and sufficient — it contains run.jobs.run"* — which is true and
insufficient, because it was written without the overrides body in mind.

It also explains why `make smoke` works: that runs the job as the operator,
who holds `roles/run.developer`, and `run.developer` does include
`runWithOverrides`.

**This is a hypothesis with good supporting logic, not a verified fact.**
Confirm it before changing the config.

### The test — one command, and the operator can run it

`roles/run.developer` includes both permissions. Granting it on **one job**
is resource-scoped, not project-wide:

```bash
eval "$(make -s env-exports ENV=dev)"
```

```bash
gcloud run jobs add-iam-policy-binding cr-$PREFIX-lightcast-1 \
  --region $REGION --project $PROJECT \
  --member serviceAccount:sa-$PREFIX-scheduler-1@$PROJECT.iam.gserviceaccount.com \
  --role roles/run.developer
```

Then fire it and check whether an execution appears:

```bash
gcloud scheduler jobs run cs-$PREFIX-lightcast-monthly-1 --location $REGION --project $PROJECT
make scheduler-debug ENV=dev
```

Check 6 showing an execution within seconds of the newest attempt in check 5
confirms it. If it still 403s, the hypothesis is wrong — move to the
alternatives below.

### If confirmed, three ways to fix it

1. **`roles/run.developer` on each job** in
   `modules/pipeline/job.tf`. One-line change, resource-scoped. Broader than
   `run.invoker` but not project-wide. Simplest, and the comment in that file
   already concedes it "would also work".
2. **A custom role** with `run.jobs.run` + `run.jobs.runWithOverrides`.
   Tightest. But this repo has a stated no-custom-roles principle
   (`modules/platform/iam.tf`), so it would be the first one — a deliberate
   reversal, not a quiet exception.
3. **Drop the overrides.** One Cloud Run job per schedule group instead of one
   per pipeline, so each scheduler posts an empty body and `run.invoker` is
   genuinely sufficient. Cleanest on permissions, most churn: it changes the
   job/scheduler topology and the `pipelines.yml` → Terraform derivation in
   `envs/*/main.tf`.

Recommendation: 1 to unblock, and record 3 as the thing to consider if OMES
objects to `run.developer`.

### If the hypothesis is wrong

Remaining candidates, roughly in order:

- **VPC Service Controls.** OMES runs org policies; a perimeter around
  `run.googleapis.com` would produce a 403 that every IAM check reads as
  fine. Ask the admin to check for a perimeter and for
  `RESOURCE_NOT_IN_SAME_SERVICE_PERIMETER` in the audit logs.
- **The v1 `namespaces` endpoint.** The scheduler calls the Knative-style v1
  API while the job is a v2 resource. If the IAM binding does not apply
  across that surface, granting on the v2 resource would not help — test by
  calling the same URL by hand with an impersonated token.
- **Org policy on service account usage**, e.g. a constraint restricting
  which identities may be impersonated.

---

## Open issue 2: the deploy principal is a person

### What is wrong

The one-time setup grants the deploy principal eleven resource-admin roles
plus `actAs` on five service accounts. It currently defaults that principal
to **whichever gcloud account is active when the script runs**.

On `owc-dpar-d` that produced:

```json
{ "role": "roles/iam.serviceAccountUser",
  "members": ["user:sswami@agency.ok.gov"] }
```

— the **admin's** account, because they ran the script from their own shell.
The operator got nothing on those accounts.

And the operator has said plainly they **must not hold admin-level roles at
all**. So neither account is right. The current design has no correct answer.

### What it should be

A dedicated service account that OMES owns, impersonated by whoever deploys:

```
sa-<prefix>-deploy-1@<project>.iam.gserviceaccount.com
```

- OMES creates it and grants it the eleven resource-admin roles and `actAs`
  on the five runtime accounts. No human holds any of it.
- Whoever deploys is granted `roles/iam.serviceAccountTokenCreator` **on that
  one account** — auditable, revocable, and not an admin role.
- Terraform and gcloud both impersonate it:
  `terraform` via `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`, gcloud via
  `--impersonate-service-account` or `gcloud config set auth/impersonate_service_account`.

This is close to the `sa-<prefix>-deployer-1` account the original Workload
Identity Federation design had, which was deleted along with the CI path. The
difference is the trust mechanism: impersonation by a named human instead of
a GitHub OIDC token.

### Work this implies

- `infra/gcloud/names.sh`: add the deploy account; decide whether its roles
  live in `TF_PRINCIPAL_ROLES` or a new array.
- `01-admin-identities.sh` and `04-standalone.sh`: create it, grant it the
  eleven roles and the five `actAs` bindings, and grant the named human
  `tokenCreator` on it. Stop granting anything to a user account.
- `Makefile`: `TF_PRINCIPAL` becomes that service account, not
  `user:$(gcloud config get-value account)`. Export
  `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` for the terraform targets and pass
  `--impersonate-service-account` to the gcloud ones.
- `00-access-check.sh`: test the permissions of the **impersonated** identity,
  not the caller's. It currently answers the wrong question for this model.
- `02-verify-admin.sh`: the forbidden-roles audit should assert that **no
  user account** holds the eleven roles, which is a stronger and more useful
  claim than the current one.
- `docs/deploy.md`: step 2 gains an impersonation step; steps 4–6 change
  owner.

The guard added in `04-standalone.sh` — refusing when the deploy principal
equals the account running the script — is a stopgap for the old model. It
should be removed when the principal becomes a service account, because then
the two can never be equal.

---

## What OMES actually enforces

Learned by hitting each one. Assume all of it applies to `owc-dpar-p` too.

| Constraint | How it showed up | Handled? |
|---|---|---|
| `constraints/gcp.resourceLocations` forbids `global` | Secret Manager refused `replication { auto {} }` | Yes — `user_managed` pinned to `var.region` |
| Default service-agent grants are stripped | Cloud Scheduler agent had no `tokenCreator`; the automatic `roles/cloudscheduler.serviceAgent` was absent | Yes — both scripts force the agent and grant it explicitly |
| No `serviceAccountAdmin` or `projectIamAdmin` for the deploy account | The entire split this repo is built around | Yes |
| No admin-level roles on a human account at all | Stated after the fact | **No** — issue 2 |
| No project IAM policy reads for the deploy account | `iam-check` runs in REDUCED mode; checks 3 and 4 of `scheduler-debug` are inconclusive | Yes — they report `????`, not `NO` |
| No log reads without `roles/logging.viewer` | Every runbook diagnostic silently returned nothing | Yes — added, eleven roles now |
| Cloud Shell has no terraform | `make up` "succeeded" having created nothing | Yes — `make install-terraform`, and `tf-check` guards every `tf-*` target |
| GCS/BigQuery multi-region `US` | Not hit — the buckets and datasets were created | Unknown; `make access-check` prints the permitted locations |

Things OMES has **not** yet been asked and will need to be:

- Will they host the Terraform state bucket? Stephen raised it early
  (*"we can hook up your instance with the state"*) and it was never
  resolved. Today both buckets are in the project.
- Is `roles/run.developer` on a single Cloud Run job acceptable? Relevant if
  issue 1's fix is option 1.
- Who owns the deploy service account in issue 2, and who may impersonate it?

---

## Failures so far, and what each one means

Chronological. Several are mistakes in this repo's own tooling — worth
knowing so they are not re-learned.

| What happened | Root cause | Status |
|---|---|---|
| `make up` reported success, created nothing | Cloud Shell ships a terraform **stub** that exits 0 | Fixed: `require-terraform.sh` guards every `tf-*` target |
| Secret creation refused | Org policy forbids `global` replication | Fixed: `user_managed` |
| `make deploy` → "could not be found", then ">> both jobs updated" | `set-image` ignored gcloud's exit status | Fixed |
| `make smoke` failed on a bq syntax error | Backslash continuation inside a single-quoted Makefile recipe; GNU make 3.81 and 4.3 disagree | Fixed; `shell-check` catches the pattern |
| `iam-check` printed `warn: command not found` ×7 | `warn()` was never defined in that script | Fixed; `shell-check` catches it |
| `access-check` said "no access to this project" | `gcloud projects test-iam-permissions` **does not exist** | Fixed: REST `testIamPermissions` |
| `make doctor` said "no quota project" right after setting one | ADC path assumed `~/.config/gcloud`; Cloud Shell uses `CLOUDSDK_CONFIG` | Fixed |
| `--dry-run` told the operator to run `iam-check` next | Dry run printed the post-apply steps | Fixed |
| scheduler-debug said `NO` when it meant "cannot see" | Permission failures reported as absence | Fixed: `????` |
| "no scheduler attempts logged yet" | `2>/dev/null` ate a permissions error; and the operator could not read logs at all | Fixed both |
| check 5 showed a bare timestamp | Filtered on `resource.type` alone, matching audit logs | Fixed: filter on the executions log |
| check 6 "has run" from a manual smoke test | An execution is not evidence the scheduler started it | Fixed: says so |
| Scheduler 403 | **Open** — see issue 1 | Open |
| `actAs` granted to the admin's own account | Principal defaults to the active gcloud account | **Open** — see issue 2 |

The recurring shape: **a check that returns a confident answer to a question
it never successfully asked.** Swallowed stderr, loose greps, wrong log
filters. `scripts/shell-check.py` now catches two mechanical variants; the
rest is a review habit.

Also unresolved and unrelated: `make lock-check` is red. Three Google client
libraries drifted upstream (`google-api-core` 2.38→2.39, `google-auth`
2.58.0→2.58.1, `google-cloud-storage` 3.14.1→3.15.0). `make lock` fixes it
and changes what the next image installs, so do it deliberately.

---

## Do these in order

1. **Test the `runWithOverrides` hypothesis** — one `add-iam-policy-binding`,
   fire, read `scheduler-debug`. Cheap, and it either closes issue 1 or rules
   out the leading theory.
2. **If confirmed, fix `modules/pipeline/job.tf`** and re-apply. Note it in
   `docs/runbook.md` under ALERT 3 — the existing entry blames the invoker
   binding, which will be wrong.
3. **Design issue 2 with OMES before touching prod.** The identity model is
   theirs to approve, and prod's setup should be run once, correctly, rather
   than fixed afterwards the way dev was.
4. **Ask the three open OMES questions** above — state hosting,
   `run.developer`, deploy account ownership.
5. **Then prod**: `snowflake_user`, the `make omes-script` hand-off, and the
   sequence in `docs/deploy.md`. Prod runs schedulers unpaused, so issue 1
   must be closed first.
6. **`make lock`**, deliberately, when out of the incident.
