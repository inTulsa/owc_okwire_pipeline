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
underscores; not starting with a digit). The schema is autodetected, so
check what landed the first time:

```bash
bq show --project_id=<project> owc_marts.<name>
```

Keep these small. This is for lookup tables, not a data-loading path.
