# Static reference data

CSVs that no pipeline produces — crosswalks and lookups a report needs and a
human maintains.

Each `<name>.csv` here is uploaded to `gs://gcs-<prefix>-raw-1/reference/`
and loaded into `owc_marts.<name>` by:

```bash
make load-reference ENV=dev
```

`make up` runs it too, so prod loads the same file dev was tested against
rather than depending on someone remembering to upload it.

**The repo is the source of truth.** The load is `--replace`, so a deploy
makes BigQuery match what is committed here. Edit the CSV, commit, deploy.
Anything typed straight into the table is overwritten.

**Conventions.** First row is the header, and the column names become the
BigQuery column names — so they must be valid identifiers (letters, digits,
underscores; not starting with a digit).

**Pin the schema for anything code-like.** Add `<name>.schema.json` next to
the CSV and it is used instead of autodetection:

```json
[
  {"name": "PROGRAMID", "type": "STRING", "mode": "NULLABLE"}
]
```

Autodetection types a column by what its values look like, and identifiers
frequently look numeric. CIP codes are the example that prompted this: every
value in `dim_soc2cip.PROGRAMID` parses as a number, so autodetect makes it
FLOAT64 — `44.0401` stops being a code, `44` becomes `44.0`, and a join
against a string CIP column elsewhere fails. Zip codes, FIPS codes, SOC
codes and account numbers all have this problem.

If you do let it autodetect, check what landed:

```bash
bq show --project_id=<project> owc_marts.<name>
```

Keep these small. This is for lookup tables, not a data-loading path.
