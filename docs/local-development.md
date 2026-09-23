# Local development

Both pipelines run outside GCP, and `--target local` reproduces their original
on-disk behavior. "Local" here means *not on Cloud Run* — a workstation or a
Cloud Shell, either works.

This is the only part of the repo that needs a Python toolchain. Deploying and
operating need none of it; see
[`deploy.md`](deploy.md).

## Setup

```bash
make setup                    # venv + deps + writes .env from the example
$EDITOR .env                  # SNOWFLAKE_USER / SNOWFLAKE_PASSWORD
make validate                 # config + all 41 SQL files, no network
```

`make help` lists every target.

`make setup` runs `uv venv --python 3.12`, and **uv downloads that
interpreter** rather than using the system one — so a system Python 3.11 is
not a blocker. uv itself is not preinstalled in Cloud Shell:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### If you do this in Cloud Shell, know where the password ends up

`.env` holds the Snowflake password in plaintext, and Cloud Shell's `$HOME`
**persists between sessions**. That is a credential sitting in a
Google-managed home directory belonging to your user account, not a
throwaway container.

It is `.gitignore`d and `make source-push` refuses to upload a tarball
containing it, so it will not escape that way. But delete it when you are
done, and prefer a workstation if you would rather the password never live in
a cloud-hosted home at all:

```bash
shred -u .env 2>/dev/null || rm -f .env
```

Nothing in the deploy path reads `.env`. The Cloud Run jobs get the password
from Secret Manager.

## What a workstation needs

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
[local-development.md](local-development.md#no-docker-locally).

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

## Running things

```bash
# One small dataset, row-limited — seconds
make run PIPELINE=lightcast DATASET=dim_area LIMIT=1000

# A whole group, row-limited
make run PIPELINE=lightcast GROUP=monthly LIMIT=100

# The scraper, writing to ./.owcdata-local/enrollment/data as it always did
make run PIPELINE=enrollment TARGET=local
```

Output lands in `exports/<pipeline>/` (gitignored). A run manifest is written
to `exports/pipeline_runs.jsonl`, so the prior-run comparison the quality gate
depends on is exercised locally too rather than only in production.

## `--limit` and what it does to the SQL

`--limit N` wraps each query in a subquery:

```sql
SELECT * FROM (
  <the file's text, verbatim>
) AS _owc_limited
LIMIT N
```

- **Files on disk are never modified.** The wrapping happens in memory.
- Seven of the 41 files end in a semicolon (`dim_area`, `dim_company`,
  `dim_edulevels`, `dim_schools`, `dim_skills`, `fact_completions`,
  `fact_completions_lagged`). A semicolon inside a subquery is a syntax error,
  so it is stripped first.
- Four files carry a semicolon **inside a `--` comment**
  (`fact_emp_2`, `fact_emp_lagged_2`, `fact_jobs_qoq`,
  `fact_jobs_lagged_qoq`). The safety scan is comment- and
  string-literal-aware so those are not mistaken for a second statement — a
  naive scan flags them and blocks CI for nothing.
- All 41 files are verified single-statement by
  `test_every_sql_file_is_single_statement_so_limit_is_safe`, and
  `prepare_query` refuses to wrap anything that is not.

## Two warnings about running locally

**Dev and prod share one Snowflake reader account.** A local run bills
Lightcast's warehouse, against the same `TULSA_FOR_YOU_WH`. Always use
`--limit` unless you specifically need a full extract, and prefer off-peak.
See open item 4.

**The enrollment cache directory is deliberately not `data/`.** It defaults to
`.owcdata-local/enrollment/data`, separate from the GCS-backed production
cache, so a local test cannot corrupt production state. `owcdata validate`
fails if that ever resolves to `./data`.

## When gcloud credentials expire

`make` targets that touch GCP run `auth-check` first, because an expired
gcloud token otherwise looks exactly like a missing resource — "no image
found", "the secret does not exist yet" — and sends you rebuilding things
that are already there.

```bash
gcloud auth login                        # the gcloud CLI
gcloud auth application-default login    # what Terraform uses — separate
```

The two are independent, so Terraform can keep working while `make build`
fails, and vice versa.

**In Cloud Shell the first line is already done for you** and the second is
not, which is exactly why the second is the one that gets forgotten.
`make doctor` reports both and names the Cloud Shell-specific fix.

## Testing

```bash
make test          # unit only, no network — 128 tests, ~3s
make test-all      # adds integration: Snowflake, a live scrape, GCS, BigQuery
make check         # lint + types + derive-check + validate + unit. What CI runs.
```

The enrollment parsing tests are the highest-value tests here. They run
against saved HTML and workbook fixtures in `tests/fixtures/enrollment/`, so
current parsing behavior is pinned without a live scrape:

- `page.html` — AEM-shaped markup with all three anchor patterns, plus decoys
  outside the grid wrapper and an orphan companion, so the container scoping
  is actually tested
- `page_redesigned.html` — the same content with every selector gone. Proves
  the "Oklahoma changed the page" path exits non-zero.
- Five workbooks covering all three column naming conventions, a title row
  above the header, a `Grade Code`/`Grade` collision, a blank-County backfill,
  and an unrecognizable sheet

When Oklahoma next changes the page, **save the new HTML over `page.html`** —
the failing tests then tell you exactly what broke.

## The enrollment script is generated

[`scrape.py`](../src/owcdata/pipelines/enrollment/scrape.py) is produced by
[`scripts/derive_scrape.py`](../scripts/derive_scrape.py) from the pristine
original. Do not edit it directly.

```bash
make diff-enrollment   # the complete change set: 9 removed lines
make derive-scrape     # regenerate after editing the derivation
make derive-check      # what CI runs
```

Each substitution in the derivation must match exactly once, so if someone
edits the original — or a formatter rewraps a line the derivation depends on —
it fails loudly instead of eroding quietly. See ADR-008.

## Verifying the exit codes

The single most important property in this repo. Break something and confirm
it is non-zero:

```bash
# Bad credentials — the original exited 0 here
SNOWFLAKE_PASSWORD=wrong .venv/bin/owcdata run lightcast --dataset dim_area --limit 10
echo $?   # 3

# A typo'd dataset
.venv/bin/owcdata run lightcast --dataset dim_aera; echo $?   # 2

# A broken config
.venv/bin/owcdata validate --pipelines-file /dev/null; echo $?   # 2
```

`tests/unit/test_exit_codes.py` covers these as subprocesses, because an
in-process assertion on an exception object would not prove what the shell
sees.

## No Docker locally

Image builds go through Cloud Build, which is also why nothing here needs a
local daemon — Docker is not installed on the maintainers' machines, and the
fact that Cloud Shell happens to have one running is irrelevant. `make build`
is a `gcloud builds submit` of the source tarball:

```bash
make build ENV=dev
```
