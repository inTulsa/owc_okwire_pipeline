# Work order: documentation pass before the prod release

**This file is the brief, not the record.** It describes work to do in one
session and should be **deleted in the commit that finishes it**. If you are
reading it and the tasks below are done, delete it.

Written 2026-09-30, at the end of the session that stood `owc-dpar-d` up
properly. 23 commits, `31309ac..HEAD` on `dev`, are the change set to audit.

- [Where things actually stand](#where-things-actually-stand)
- [Task 1: retire what is finished](#task-1-retire-what-is-finished)
- [Task 2: fix the claims that are now false](#task-2-fix-the-claims-that-are-now-false)
- [Task 3: reconcile deploy.md with what actually happened](#task-3-reconcile-deploymd-with-what-actually-happened)
- [Task 4: the ADRs](#task-4-the-adrs)
- [Task 5: what still genuinely blocks prod](#task-5-what-still-genuinely-blocks-prod)
- [Task 6: the dev to prod release](#task-6-the-dev-to-prod-release)
- [Out of scope](#out-of-scope)
- [Definition of done](#definition-of-done)

---

## Where things actually stand

**`owc-dpar-d` works end to end and is the reference implementation.** Both
pipelines run, Cloud Scheduler starts them, 35 lightcast datasets published
successfully, `dim_soc2cip` is loaded, and PowerBI reads `owc_marts` through
a service-account key.

**Deploys run as `sa-owc-dpar-d-deploy-1`**, impersonated by two named
people. No human holds a resource-admin role *by design* — but the old
grants have not been removed yet, so that is not yet true in fact. See task
5.

**`owc-dpar-p` does not exist.** No project resources, no service accounts.
Everything about prod is still theoretical, which is exactly why the
documentation has to be right before it is built.

**`dev` and `prod` branches have diverged**: 32 commits on dev that prod
does not have, 35 on prod that dev does not. Prod's are all
`Promote dev to prod: <subject>` cherry-picks, so its *tree* is simply
older. A merge is clean — verified with `git merge-tree`. See task 6.

---

## Task 1: retire what is finished

These were open and are now closed. Remove them rather than marking them
done — a list of solved problems is noise in a handoff.

**`OPEN-ITEMS.md` item 9, "A full lightcast sync has never been run."**
It has. All 35 datasets published on 2026-09-30, started by Cloud Scheduler.
Delete the item. If anything survives, it is one line somewhere durable
recording that the 35-way fan-out at parallelism 4 has been exercised once —
that is the only useful residue.

**`OPEN-ITEMS.md` item 7, "Create the deploy identity on each project."**
Done on dev. Rewrite as prod-only, and fold in the cleanup from task 5,
which is the part that is genuinely unfinished.

**`OPEN-ITEMS.md` "Also worth knowing" → the PowerBI JSON key.**
The key exists and works. What remains is not a decision but two facts:
the key is deliberately not rotated (ADR-006), and dev needed
`roles/bigquery.readSessionUser` granted by hand because it predates that
entry in `names.sh`. Keep those; drop the rest.

**Check whether the key's local copy was destroyed.** `make powerbi-key`
prints the `shred` command but cannot enforce it. Ask, and if it is still on
disk or in a Downloads folder, say so plainly in whatever replaces this
file.

---

## Task 2: fix the claims that are now false

Each of these was true when written and is not any more. Verified stale on
2026-09-30.

| Where | Says | Reality |
|---|---|---|
| `README.md`, the banner | "no project has that account yet" | dev has it, with two operators holding `tokenCreator` |
| `gcp-reference.md`, the OMES constraints table | "Not yet applied to either project" | applied to dev |
| `OPEN-ITEMS.md` item 7 | "dev is running without it" | dev runs on it |

Then sweep for the same class of thing rather than trusting this table to be
complete. `grep -rn "not yet\|never been\|has not been\|does not exist" docs/ README.md`
and read every hit against the current project.

**The lesson this session kept re-learning applies to prose too.** Five
separate checks reported confident answers to questions they had never
successfully asked — `scheduler-debug` check 1, `access-check`'s verdict,
`iam-check` on an unreadable service account, `image-digest` on a swallowed
error, `verify-separation` on a polluted JSON parse. A document asserting a
state nobody re-verified is the same failure in a different medium.

---

## Task 3: reconcile deploy.md with what actually happened

**This is the most valuable task in the pass**, because prod will be built
from `deploy.md` by someone who was not here.

Standing dev up hit **eight** things the document did not predict. Some are
now written down, some are not, and none of them were in the procedure
before the deploy started:

| What happened | Documented now? |
|---|---|
| `iam-check` reported a service account it could not read as MISSING, and stopped the deploy | fixed in code |
| `tf-bootstrap` refused to plan because `scheduler_job_iam_in_terraform` gave a resource a `count`, needing a one-time `terraform state mv` | runbook |
| `image-digest` called `gcloud artifacts docker images describe`, which needs `containeranalysis.occurrences.list` | fixed in code |
| Cloud Shell had **no IPv6 route**, so every `terraform` API call failed while gcloud worked. `GODEBUG=netdns=cgo` and `/etc/gai.conf` do nothing, because Terraform is built `CGO_ENABLED=0` | runbook |
| `gcloud auth application-default login` run *after* `env-exports` wrote an `impersonated_service_account` ADC, which fails with a message about quota projects | deploy.md + `make doctor` |
| A new Cloud Shell session silently loses the impersonation, and the first failure names a numeric service-account id | `auth-check` |
| PowerBI Desktop authenticates differently from the PowerBI workspace | deploy.md, ADR-006 |
| The PowerBI connector needs `bigquery.readSessionUser`, which `jobUser` does not include | `names.sh`, deploy.md |

**Read `deploy.md` start to finish as though building prod tomorrow, and
make the order of operations match what actually worked.** Specifically:

1. The ADC / `env-exports` ordering is load-bearing and currently reads as
   advice. It should read as a numbered sequence with the failure mode
   attached.
2. The IPv6 problem is in the runbook under a symptom heading. Someone
   following `deploy.md` will not look there. Decide whether prod's
   procedure needs a "check IPv6 before you start" line, given a broken VM
   costs an hour.
3. `scheduler_job_iam_in_terraform = false` — **the fallback branch has
   never been executed.** OMES granted `run.admin`, so the `count = 0` path
   is untested code with documentation promising it works. Either test it on
   a throwaway project, or say in the doc that it is untested.

---

## Task 4: the ADRs

Ten of them, inline in `architecture.md`, indexed in `adr/README.md`.

**They contain no environment-specific content** — verified, they are design
decisions and read correctly for prod. So this is tidying, not rewriting.

- **They are out of order in the file**: 001-006, then 009, 010, then 007,
  008. The index table is in order. Reorder the file.
- **ADR-006 was rewritten this session** to record that the PowerBI key is
  not rotated on a schedule, with the events that force a replacement. Read
  it once more against what was actually built.
- **ADR-002, marts tables unpartitioned and unclustered**, says clustering
  is deferred because column order depends on what PowerBI filters on, and
  that is unknowable until `OPEN-ITEMS` item 5 is settled. **PowerBI is now
  connected.** Ask which mode was used — Import or DirectQuery — and if that
  answers item 5, ADR-002 can stop deferring and item 5 can close.
- **ADR-010 ends "There are no custom roles in this project."** Still true.
  Keep it that way: the `run.developer` fallback documented in `job.tf`
  offers a custom role as a last resort, so if anyone ever takes it, ADR-010
  becomes false and must be amended in the same commit.

---

## Task 5: what still genuinely blocks prod

Carry every one of these into whatever replaces this file. None are
cosmetic.

**1. The old grants are still on human accounts.** This is the big one. The
deploy identity exists and is used, but `gtorianyk@agency.ok.gov` and
`gsingh@agency.ok.gov` still hold `storage.admin`, `bigquery.admin`,
`secretmanager.admin`, `artifactregistry.admin`, `cloudscheduler.admin`,
`run.developer`, `monitoring.editor`, `logging.configWriter`,
`bigquery.dataOwner`, `cloudbuild.editor` — and
`roles/serviceusage.serviceUsageAdmin`, which is one of the four roles
`TF_PRINCIPAL_FORBIDDEN_ROLES` exists to keep off people. Until an admin
removes them, the property this whole split was built to achieve is not
true, and OMES's objection stands.

```bash
make iam-check ENV=dev STRICT=1
```

That output is the list and the receipt. Run it as the admin for the full
audit; the deploy identity cannot read the project IAM policy.

**2. `schedulers_paused = false` in `envs/dev/terraform.tfvars` is
temporary.** It is commented as such. Dev's lightcast scheduler fires
`0 6 1 * *`. The moment prod is live, both environments run the same 35
Snowflake queries at the same minute and bill Lightcast twice. Revert it
before prod's first apply, or decide deliberately not to.

**3. `snowflake_user` in `envs/prod/terraform.tfvars` is `REPLACE_ME@`.**
The plan rejects it on purpose.

**4. `make lock-check` is red.** Three Google client libraries have drifted:
`google-auth` 2.58.0→2.58.1, `google-cloud-storage` 3.14.1→3.15.0, and
`google-api-core`. `make lock` fixes it and changes what the next image
installs, so do it deliberately and rebuild — not during a release.

**5. `monitoring.editor` carries `serviceusage.services.enable`**
(`OPEN-ITEMS` item 10), so the deploy identity can enable APIs even though
the design says it cannot. Latent — no Terraform resource uses it — but the
claim is stated as a property of the role set. The narrower replacement is
`alertPolicyEditor` + `notificationChannelEditor`.

**6. `readSessionUser` on dev was granted by hand.** It is in
`RUNTIME_PROJECT_GRANTS` now, so prod gets it from the setup script. Confirm
dev's live grant and the script agree, so `iam-check` does not report drift.

**7. Terraform state hosting** (`OPEN-ITEMS` item 8) was raised by OMES and
never answered. Cheaper to settle before prod's first apply than to migrate
state after.

**8. Items 1-6 of `OPEN-ITEMS`** are unchanged and still need their owners:
the quarterly/yearly dataset lists, the enrollment repo history, the
Snowflake reader-account confirmation, the Lightcast parallelism
conversation, the PowerBI mode and licensing, and the license audience
question.

---

## Task 6: the dev to prod release

**Do not merge until tasks 1-5 are done.** The point of the
`Promote dev to prod:` convention is that prod's history means "this was
verified." Promoting a documentation pass that has not been reviewed
defeats it.

When ready:

```bash
git merge-tree --write-tree origin/prod origin/dev   # confirm still clean
```

A merge was verified conflict-free on 2026-09-28. The histories diverged
because prod was built by cherry-picking, so this is a merge commit, not a
fast-forward. **After it, future promotes become fast-forwards** — which
ends the 35-cherry-pick pattern that made prod look diverged when its tree
was only older.

The only file prod has that dev does not is `docs/HANDOFF.md`, retired
deliberately. The merge removes it. That is correct.

Then the prod build itself is `deploy.md`, and the task-3 work is what makes
that safe. Prod differs from dev in four settings; `schedulers_paused =
false` and `freshness_check_enabled = true` mean **a permissions mistake in
prod does not appear at a terminal — it appears as a 403 on the 1st of the
month.** The scheduler proof in `deploy.md#prove-the-scheduler` is not
optional there.

---

## Out of scope

Do not do these in the documentation pass:

- **`make lock`.** It changes what the image installs. Separate change,
  separate test.
- **Narrowing `monitoring.editor`.** Needs an admin, a re-run of
  `gcloud-admin`, and verification that the two narrower roles cover the
  module. Record it; do not attempt it.
- **Building prod.** This pass makes prod buildable. It is not the build.
- **Rewriting ADRs that are merely old.** An accepted decision does not need
  refreshing because time passed. Only fix what is wrong.

---

## Definition of done

- `make docs-check shell-check names-check` pass, and `make validate` reports
  35 datasets.
- `grep -rn "not yet\|never been\|has not been" docs/ README.md` returns
  nothing that is false.
- `OPEN-ITEMS.md` contains only things that are actually open, each with an
  owner-type and a consequence for leaving it.
- Someone who was not in this session can build `owc-dpar-p` from
  `deploy.md` alone, including the eight surprises in task 3.
- The README banner describes the real current blocker.
- **This file is deleted**, and anything in it that is still true lives in
  `OPEN-ITEMS.md`, `deploy.md`, `gcp-reference.md` or the runbook.
