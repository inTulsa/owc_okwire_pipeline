# Local development

Both pipelines run on a laptop, and `--target local` reproduces their original
on-disk behavior.

## Setup

```bash
make setup                    # venv + deps + writes .env from the example
$EDITOR .env                  # SNOWFLAKE_USER / SNOWFLAKE_PASSWORD
make validate                 # config + all 41 SQL files, no network
```

`make help` lists every target.

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

Docker is not installed on the maintainers' machines. Image builds go through
Cloud Build:

```bash
make build ENV=dev
```
