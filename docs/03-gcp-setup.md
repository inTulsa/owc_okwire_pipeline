# GCP environment reference

**This is not a walkthrough.** The steps to deploy are in
[`09-gcloud-deploy.md`](09-gcloud-deploy.md), and they are the only ones.
This document explains what those steps create, what you have to fill in
yourself, and why each thing is shaped the way it is — the questions that come
up *while* following that walkthrough, or six months later when someone asks
why a bucket is configured a particular way.

- [What has to exist before anything here runs](#what-has-to-exist-before-anything-here-runs)
- [The two files you fill in](#the-two-files-you-fill-in)
- [The Snowflake password](#the-snowflake-password)
- [Why the image is pinned by digest](#why-the-image-is-pinned-by-digest)
- [Region co-location is mandatory](#region-co-location-is-mandatory)
- [Identity separation](#identity-separation)
- [Terraform guardrails](#terraform-guardrails)
- [What prod does differently](#what-prod-does-differently)

## What has to exist before anything here runs

- **A GCP project with billing linked, one per environment** (`owc-dpar-d`,
  `owc-dpar-p`). **This repo does not create it.** At OMES the project and its
  spoke network — VPC, subnet, Cloud NAT, and the router back to the state
  transit hub — are provisioned separately from
  `omes-net-gcp-tf-owc-dpar-<env>`, per the Phase Two infrastructure
  architecture. This repo deploys the data platform *into* a project that
  already exists.
- **Someone who can run the one privileged step once** — see
  [the access table](08-developer-setup.md#access-you-need-granted). After
  that, nobody needs `projectIamAdmin` or `serviceAccountAdmin` again.
- **The Snowflake reader-account password.**
- **A distribution list for alerts** — not an individual's address, so people
  join and leave the rotation without a Terraform change.

The Cloud Run jobs use **default egress**, not the spoke VPC: reaching
Snowflake and the OSDE site needs no special network path, so nothing here
coordinates with the network layer.

## The two files you fill in

Both live in `infra/terraform/envs/<env>/`, and they are already filled in for
`owc-dpar-d` and `owc-dpar-p`. You only touch them to point at a *different*
project.

### `terraform.tfvars`

| Variable | Notes |
|---|---|
| `project_id` | This environment's project |
| `name_prefix` | Drives every resource name via the OMES convention `<type>-<name_prefix>-<qualifier>-<seq>`, so `owc-dpar-d` gives `gcs-owc-dpar-d-raw-1`. Normally identical to `project_id`. Capped at 14 characters, because it is embedded in service account ids and GCP caps those at 30 — the plan fails with that sentence if you exceed it. |
| `state_bucket` | This environment's Terraform state bucket. Must match `backend.tf` — see below. |
| `alert_emails` | The distribution list |
| `snowflake_user` | The login. Not a secret; the password goes to Secret Manager. Rejected at plan time if left as the `REPLACE_ME` placeholder. |
| `manage_identities`, `manage_apis`, `enable_wif` | All `false`. See [09](09-gcloud-deploy.md#where-the-line-is-drawn). Changing one means re-granting a role you deliberately gave up. |
| `github_repository`, `allowed_refs` | Read only when `enable_wif = true`, which it is not. |
| `billing_account` | Only if you want the budget alert. Off by default (`billing_budget_amount = 0`). |

### Testing against your own project

Change the first three values here **and** the bucket literal in `backend.tf`
— four values, two files. `-var` overrides are not enough: `make up` drives
`gcloud-admin`, `source-push`, `iam-check`, `build`, `set-image` and `smoke`,
and all of them read `project_id` and `name_prefix` from this file, while
`-var` reaches only Terraform.

Do it on a throwaway branch so `dev` never carries a test project's values and
cleanup is deleting the branch:

```bash
git switch -c test/my-project      # edit both files, commit, push
```

Use **`envs/dev`**, never `envs/prod`. Prod sets `schedulers_paused = false`,
so an apply there creates live schedulers that fire the monthly schedule at
Lightcast's warehouse.

### `backend.tf`, in the same directory

Terraform's backend block **cannot read a variable** — not `state_bucket`, not
anything. The bucket is a committed literal, so it is the one value you set in
two places:

```hcl
terraform {
  backend "gcs" {
    bucket = "gcs-owc-dpar-d-tfstate-1"   # must equal state_bucket above
    prefix = "env/dev"                     # leave this alone
  }
}
```

Leave `prefix` alone. It separates the two environments' state *within* a
bucket, which matters only if you ever share one — and you should not.

A mismatch does not say "mismatch". It surfaces as:

```
Error: Failed to get existing workspaces: querying Cloud Storage failed:
storage: bucket doesn't exist
```

which reads like the bucket is missing when it is fine and Terraform is simply
looking for a different one. `make iam-check` catches this before an apply
does, and distinguishes it from the credentials fault that produces the
identical message.

### One state bucket per environment, in that environment's own project

Bucket names are **globally unique**, so a shared name is not one bucket per
project — it is one bucket total, in whichever project was set up first, which
silently puts prod's state inside dev. Dev is where people feel free to break
things; that inverts the trust relationship and nothing downstream would
surface it. `01-admin-identities.sh` refuses to continue if the bucket it finds
belongs to a different project.

## The Snowflake password

Terraform creates the secret **container** and never the value, deliberately,
so the password stays out of Terraform state. `make up` stops and asks for it
rather than carrying on:

`$PROJECT` and `$PREFIX` come from `eval "$(make -s env-exports ENV=dev)"`
— see [09](09-gcloud-deploy.md#shell-setup):

```bash
printf '%s' 'THE_PASSWORD' | \
  gcloud secrets versions add sm-$PREFIX-snowflake-password-1 \
    --data-file=- --project $PROJECT
```

It has to exist **before** the apply that creates the Cloud Run jobs. The
lightcast job mounts `SNOWFLAKE_PASSWORD` from `versions/latest` and `latest`
cannot resolve to nothing — with no version, job creation fails several
minutes into an apply with:

```
Secret projects/.../secrets/sm-<prefix>-snowflake-password-1/versions/latest was not found
```

`make tf-apply` preflights this, so a forgotten password costs a second rather
than a failed apply.

Password auth is correct here and is **not** deprecated: Snowflake's password
phase-out explicitly exempts reader accounts. See
[ADR-004](01-architecture.md#adr-004-snowflake-password-auth-is-kept) and
[open item 3](OPEN-ITEMS.md).

## Why the image is pinned by digest

Terraform **requires a digest**, not a tag, and the variable has no default —
a forgotten image should be a plan error, not a job that cannot pull at 06:00.

The job's image field is also in `lifecycle.ignore_changes`, so that an
incident-time `gcloud run jobs update --image` is not silently reverted by the
next unrelated apply. The consequence is that **`terraform apply` will never
move a job onto a newly built image**, which is why `make set-image` exists and
why `make up` runs it.

## Region co-location is mandatory

One `location` variable feeds both the GCS buckets and all three BigQuery
datasets. This is not a preference: a load job from a bucket in one location
into a dataset in another **fails outright**. Never set them separately, and
never mix them between environments you plan to copy data between.

## Identity separation

Each pipeline has its own service account, and every grant is scoped to a
specific resource — a bucket prefix, one secret, one dataset. The scraper has
no business holding the Snowflake secret; the Lightcast job has no business
writing the scrape cache.

```bash
make verify-separation ENV=dev
```

```text
Identity separation — owc-dpar-d (prefix owc-dpar-d)

  OK       enrollment has no access to the Snowflake secret
  OK       lightcast has no access to the enrollment state bucket
  OK       PowerBI has no grant on owc_staging
  OK       PowerBI has no grant on owc_ops
  OK       control: PowerBI IS granted on owc_marts (so the checks above can detect a grant)

Separation verified.
```

The last line is a **positive control**, and it is the point of the whole
thing. Every other assertion passes by *not* finding a service account in a
policy — which is also exactly what happens when the lookup is broken, the name
is misspelled, or you lack permission to read the policy at all. So the control
asserts a grant that must exist; if it cannot find that one, none of the
negative results mean anything and the command exits non-zero.

`make up` runs this at the end.

## Terraform guardrails

`prevent_destroy` is set on the raw bucket, the enrollment state bucket, and
`owc_marts`. In prod, `raw_bucket_force_destroy = false` as well.

The realistic disaster for a small team is a fat-fingered `terraform destroy`,
not a quota.

The state and source buckets are created by `01-admin-identities.sh` rather
than by Terraform, so a `terraform destroy` on a scratch dev environment cannot
take either the state or the source code with it.

## What prod does differently

Run [`09-gcloud-deploy.md`](09-gcloud-deploy.md) again with `ENV=prod`. The
roots are deliberately near-identical so a change verified in dev reaches prod
verbatim — `diff` them and you should see exactly four differences:

| Setting | dev | prod | Why |
|---|---|---|---|
| `env_name` | `dev` | `prod` | Namespaces the log-based metrics and prints in alert titles. |
| `raw_bucket_force_destroy` | `true` | `false` | Lets `terraform destroy` clean up a scratch environment. Never true in prod. |
| `schedulers_paused` | `true` | `false` | **The important one.** Both read the same `pipelines.yml`, so without it dev fires prod's exact schedule — 41 Snowflake queries at 06:00 on the 1st, the same minute as prod, every month. Those credits bill to **Lightcast**, and both environments would contend for `TULSA_FOR_YOU_WH`. |
| `freshness_check_enabled` | `false` | `true` | Follows the line above. With schedulers paused, "has this run inside its interval?" is permanently no, so the alert would fire monthly for working-as-intended — on the same channel prod uses. |

Dev's schedulers are **created but paused**, not omitted, so the `oauth_token`
wiring and the `run.invoker` grant are exercised and drift-detected in dev
rather than first tried in prod. To test one, resume it by hand — the next
apply pauses it again:

```bash
gcloud scheduler jobs resume cs-$PREFIX-lightcast-monthly-1 --location $REGION
```

Three things are genuinely prod-only:

- **`snowflake_user`** — the prod tfvars ship a `REPLACE_ME@` placeholder,
  rejected at plan time. This value is only used at runtime, so a wrong one
  applies perfectly cleanly and then fails at 06:00 on the 1st, unattended, a
  month after the mistake.
- **The password** goes into `sm-owc-dpar-p-snowflake-password-1` — a different
  secret in a different project. Dev's value is not reachable from prod.
- **The freshness scheduled query exists only in prod**, which means the
  BigQuery Data Transfer agent's `tokenCreator` grant is first exercised there.
  `01-admin-identities.sh` creates it in both environments precisely so prod is
  not the first place it is tried.

Prod is a separate project with its own state, source bucket, registry and
identities. Nothing in it depends on dev, and nothing in dev can reach it.
