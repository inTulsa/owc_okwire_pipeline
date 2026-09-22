# Developer setup

What a workstation needs before it can do anything useful with this repo.
Start here; [`05-local-development.md`](05-local-development.md) covers
running the pipelines once you are set up, and
[`03-gcp-setup.md`](03-gcp-setup.md) covers standing up an environment.

## Check first, install second

```bash
make doctor
```

```text
Toolchain

  ok       terraform    1.13.4  (CI pins 1.13.4)
  ok       python3      3.13.6
  ok       uv           0.11.28
  ok       git          2.39.5
  ok       make         3.81
  ok       gcloud       533.0.0
  ok       bq           installed
  ok       gh           2.94.0

Not required: Docker. Images build in Cloud Build; nothing here runs a local daemon.

Credentials

  ok       gcloud auth  you@tulsaforyou.com
  ok       ADC          quota project: owc-dpar-d

Ready. Next: docs/03-gcp-setup.md
```

It exits non-zero if anything required is missing, and names the install
command. Run it again after fixing something.

**Why a command rather than a checklist:** a toolchain problem hit in the
middle of a GCP setup does not look like a toolchain problem. A missing
`bq` component surfaces as a failed query. Application Default Credentials
pointed at a dead project surface as `storage: bucket doesn't exist`, which
reads as a broken bootstrap. Both cost an afternoon; this costs a second.

## What you need

| Tool | Minimum | Why | Install |
|---|---|---|---|
| **gcloud** | any current | Everything touching GCP. Also provides `bq`. | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) |
| **bq** | ships with gcloud | Every BigQuery query in the runbook. Absent from some minimal installs. | `gcloud components install bq` |
| **terraform** | **>= 1.9** | All infrastructure. CI pins **1.13.4**; match it to avoid state-format surprises. | [developer.hashicorp.com](https://developer.hashicorp.com/terraform/install) |
| **Python** | **>= 3.12** | The pipelines, and the repo's own scripts. | `brew install python@3.12` |
| **uv** | any current | Creates the venv and compiles `requirements.txt`. | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| **git** | any | — | preinstalled, or `brew install git` |
| **make** | any | The interface to everything. macOS's 3.81 is fine. | preinstalled |
| **gh** | any current | Only `make gh-vars`. Skip it if you are not wiring up CI. | `brew install gh` |

### You do not need Docker

Images build in Cloud Build, and the only `docker` string in this repo is
inside `gcloud artifacts docker images`. Nothing runs a local daemon. See
[05-local-development.md](05-local-development.md#no-docker-locally).

## Authenticate twice

The single most common way a new machine fails. `gcloud` and Terraform use
**different** credentials, and having one without the other produces an
error that names neither:

```bash
gcloud auth login                                    # the gcloud CLI itself
gcloud auth application-default login                # what TERRAFORM uses
gcloud config set project <this environment's project>
gcloud auth application-default set-quota-project <same project>
```

The last two are **per environment** — run them again when you switch
between dev and prod.

The quota project matters more than it looks. Terraform's GCS backend bills
every call to whatever `quota_project_id` sits in your ADC; if that project
is deleted or inactive, every call returns `404 The requested project was
not found`, which Terraform reports as `storage: bucket doesn't exist`.
`make doctor` and `bootstrap.sh` both check this.

## Access you need granted

Tooling is the easy half. These take longer to obtain, so start them early:

| Access | Scope | Needed for |
|---|---|---|
| **GCP project role** | `roles/owner`, or enough to create service accounts and set IAM | The whole of `03-gcp-setup.md`. The first apply must be run by a human with this — the deployer cannot grant itself the permissions it needs. |
| **GitHub repo** | write | Normal development |
| **GitHub repo** | admin | `make gh-vars` (repository variables) and branch protection on `prod` |
| **Snowflake** | the reader account login + password | The lightcast pipeline. Password goes to Secret Manager, never into Terraform. |
| **Alert distribution list** | an address you can add members to | `alert_emails`. Use a list, not a person, so the rotation changes without a Terraform change. |
| **Billing account** | `roles/billing.costsManager` | **Only** if you enable the budget alert. It is off by default. |

## Platform notes

**macOS + zsh.** zsh does not treat `#` as a comment interactively
(`INTERACTIVE_COMMENTS` is off by default, unlike bash). Pasting a
multi-line block that contains comments produces `command not found: #` and
glob errors on the prose. Every multi-step check in this repo is a `make`
target partly for that reason — prefer `make verify-separation` over
pasting a block.

**The Makefile runs bash**, not your login shell (`SHELL := /bin/bash`), so
recipes behave the same regardless of what you use interactively. macOS's
bash 3.2 is sufficient; nothing here needs bash 4.

**`uv` version and `make lock`.** `requirements.txt` is compiled by `uv pip
compile`, and `make lock-check` runs in CI. If your `uv` resolves
differently from whoever last ran `make lock`, the check fails on a diff you
did not intend. Re-run `make lock` and commit the result rather than
hand-editing.

## First run

```bash
make doctor      # tools and credentials
make setup       # venv + dependencies
make check       # lint, types, tests, lockfile, docs — everything CI runs
```

`make check` needs no cloud credentials and touches no network. If it
passes, your machine is working.

Then: [`05-local-development.md`](05-local-development.md) to run a pipeline
locally, or [`03-gcp-setup.md`](03-gcp-setup.md) to stand up an environment.
