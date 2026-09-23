# Developer setup

Two ways to work with this repo, and the first one installs nothing.

| | Use it for | Setup cost |
|---|---|---|
| **[Cloud Shell](#cloud-shell-the-default)** | Standing environments up, deploying, operating, running the runbook | None. Fetch the repo and go. |
| **[A workstation](#a-workstation)** | Editing code, running the pipelines locally, running the tests | A toolchain install |

The split is real, not stylistic: **the deploy path needs no virtualenv, no
`uv`, and not Python 3.12.** Every step in `make up` is shell and API calls.
Python 3.12 and the venv exist for `make check`, `make test` and `make run` —
that is, for changing the code, not for deploying it.

```bash
make doctor
```

reports the two groups separately and exits non-zero only if the **Deploy**
group is incomplete.

## Cloud Shell, the default

Cloud Shell ships gcloud, `bq`, terraform, git, make and python3 — the whole
Deploy group — and authenticates gcloud as the account you signed into the
console with. There is nothing to install.

Run `make doctor` rather than trusting that sentence: it names what is
actually there and, for anything missing, the command that fixes it. The
image changes over time and this document does not.

```bash
cd ~ && git clone https://github.com/inTulsa/owc_okwire_pipeline.git owc && cd owc
make doctor
```

```text
Google Cloud Shell  (project: owc-dpar-d)

Deploy — required. This is all 'make up' needs.

  ok       gcloud       <version>
  ok       bq           installed
  ok       terraform    <version>  (rehearsed on 1.13.4)
  ok       python3      <version>
  ok       git          <version>
  ok       make         <version>
  ok       bash         <version>

Development — optional. Needed for 'make check', 'make test', 'make run'.

  warn     python 3.12  system python3 is <version> — 'make setup' has uv
                        fetch 3.12, so this is fine
  warn     uv           not installed — needed only by 'make setup'/'make lock'
  warn     venv         not created — run 'make setup' if you want to run tests
  warn     gh           not installed — only 'make gh-vars'

Credentials

  ok       gcloud auth  you@tulsaforyou.com
  MISSING  ADC          Terraform has no credentials. Cloud Shell logs gcloud
                        in for you but NOT Terraform:
                        gcloud auth application-default login

Cloud Shell notes

  ok       workspace    /home/you/owc is under $HOME, which persists
```

Warnings in the Development group are expected and fine. The one thing Cloud
Shell does **not** do for you is Terraform's credentials — see
[Authenticate twice](#authenticate-twice).

Can't reach GitHub from here? Upload a tarball, or fetch the project's own
mirror — both in
[`09-gcloud-deploy.md`](09-gcloud-deploy.md#get-the-code).

### Three Cloud Shell facts worth knowing up front

- **Only `$HOME` persists.** Work in `~/owc`. `make doctor` warns if you are
  somewhere that gets wiped.
- **`$HOME` is deleted after 120 days of inactivity** — a realistic interval
  for a monthly pipeline. Losing it costs one `git clone`.
- **Sessions end after ~20 minutes idle, 12 hours maximum.** Cloud Shell runs
  inside tmux, so `tmux attach` recovers a dropped `terraform apply`. Do that
  rather than starting a second apply against the same state.

## A workstation

Needed to change the code — the tests, the linters and the pipelines all want
the venv. Everything in the deploy path works here identically; Cloud Shell is
a default, not a requirement, and it has a weekly usage quota that a
workstation does not.

| Tool | Minimum | Group | Install |
|---|---|---|---|
| **gcloud** | any current | Deploy | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) |
| **bq** | ships with gcloud | Deploy | `gcloud components install bq` |
| **terraform** | **>= 1.9** | Deploy | [developer.hashicorp.com](https://developer.hashicorp.com/terraform/install) |
| **git**, **make**, **bash** | any | Deploy | preinstalled on macOS and Linux |
| **python3** | any 3.x | Deploy | preinstalled. Used only to parse small JSON blobs. |
| **Python 3.12** | **>= 3.12** | Development | `make setup` has `uv` fetch it — a system 3.11 is not a blocker |
| **uv** | any current | Development | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| **gh** | any current | Neither today | Only `make gh-vars`, which needs `enable_wif = true` |

```bash
make doctor      # tools and credentials
make setup       # venv + dependencies
make check       # lint, types, tests, lockfile, docs — everything CI runs
```

`make check` needs no cloud credentials and touches no network. If it passes,
your machine is working.

### You do not need Docker

Images build in **Cloud Build**. The only `docker` string in this repo is
inside `gcloud artifacts docker images`, and nothing runs a local daemon —
including in Cloud Shell, where one happens to be available and is still not
used. See
[05-local-development.md](05-local-development.md#no-docker-locally).

## Authenticate twice

The single most common way setup fails, in Cloud Shell as much as on a
laptop. `gcloud` and Terraform use **different** credentials, and having one
without the other produces an error that names neither.

**In Cloud Shell** the first line is already done for you, which is exactly
why the second gets skipped:

```bash
gcloud config set project <this environment's project>
gcloud auth application-default login                # what TERRAFORM uses
gcloud auth application-default set-quota-project <same project>
```

**On a workstation**, add the login Cloud Shell gives you free:

```bash
gcloud auth login                                    # the gcloud CLI itself
```

The project lines are **per environment** — run them again when you switch
between dev and prod.

The quota project matters more than it looks. Terraform's GCS backend bills
every call to whatever `quota_project_id` sits in your ADC; if that project is
deleted or inactive, every call returns `404 The requested project was not
found`, which Terraform reports as `storage: bucket doesn't exist`.
`make doctor` checks this and names the fix.

## Access you need granted

Tooling is the easy half. These take longer to obtain, so start them early.

There are **two** levels of GCP access, and only the first is hard to get. See
[`09-gcloud-deploy.md`](09-gcloud-deploy.md#where-the-line-is-drawn) for why
the line is there.

| Access | Scope | Needed for |
|---|---|---|
| **GCP, privileged** | `roles/iam.serviceAccountAdmin` + `roles/resourcemanager.projectIamAdmin` + `roles/serviceusage.serviceUsageAdmin` | `make gcloud-admin`, **once per project**, and `make iam-check STRICT=1` afterwards. In an OMES project this is theirs to run, from `make gcloud-admin-dry-run` output. |
| **GCP, day to day** | the ten resource-admin roles `make gcloud-admin` grants, plus `serviceAccountUser` on five accounts | Everything else: `make up`, `make build`, `make tf-apply`, `make smoke`. Deliberately cannot read or write the project IAM policy. |
| **Snowflake** | the reader account login + password | The lightcast pipeline. Password goes to Secret Manager, never into Terraform. |
| **Alert distribution list** | an address you can add members to | `alert_emails`. Use a list, not a person, so the rotation changes without a Terraform change. |
| **Billing account** | `roles/billing.costsManager` | **Only** if you enable the budget alert. It is off by default. |
| **GitHub repo** | write, and admin for `make gh-vars` | Not needed today — `enable_wif = false`, and OMES cannot federate a personal GitHub account. Revisit when their own instance is wired up. |

## Platform notes

**Shell comments when pasting.** zsh does not treat `#` as a comment
interactively (`INTERACTIVE_COMMENTS` is off by default, unlike bash), so
pasting a multi-line block containing comments produces `command not found: #`
and glob errors on the prose. Cloud Shell defaults to bash and does not have
this problem. Every multi-step check in this repo is a `make` target partly
for that reason — prefer `make verify-separation` over pasting a block.

**The Makefile runs bash**, not your login shell (`SHELL := /bin/bash`), so
recipes behave identically whatever you use interactively. macOS's bash 3.2 is
sufficient; nothing here needs bash 4.

**`uv` version and `make lock`.** `requirements.txt` is compiled by `uv pip
compile`, and `make lock-check` runs in CI. If your `uv` resolves differently
from whoever last ran `make lock`, the check fails on a diff you did not
intend. Re-run `make lock` and commit the result rather than hand-editing.

## Next

- Deploying or operating an environment:
  [`09-gcloud-deploy.md`](09-gcloud-deploy.md)
- Running a pipeline and changing code:
  [`05-local-development.md`](05-local-development.md)
- An alert fired: [`02-runbook.md`](02-runbook.md)
