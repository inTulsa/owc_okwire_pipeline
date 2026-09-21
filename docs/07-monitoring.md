# Monitoring

Nine alerts. Every one exists because of a specific way this system can fail
quietly.

## The alerts

| # | Alert | Mechanism | Applies to | Where defined |
|---|---|---|---|---|
| 1 | Task failed | `run.googleapis.com/job/completed_task_attempt_count`, `result="failed"` > 0 | both | `modules/pipeline/alerts.tf` |
| 2 | **Didn't run** | Freshness scheduled query over `owc_ops.pipeline_runs` | both | `modules/platform/monitoring.tf` |
| 3 | Scheduler failing | Log metric, `resource.type="cloud_scheduler_job"`, `severity>=ERROR` | both | `modules/platform/monitoring.tf` |
| 4 | Quality check failed | Log metric on `jsonPayload.event="quality_check_failed"` | both | per-pipeline `event_alerts` |
| 5 | Row count / max(YEAR) drift | Same metric, narrowed to `jsonPayload.check` | lightcast | per-pipeline `event_alerts` |
| 6 | **Scrape found nothing** | Log metric on `jsonPayload.event="no_source_files_found"` | enrollment | per-pipeline `event_alerts` |
| 7 | Workbook reshape skipped | Log metric on `jsonPayload.event="workbook_reshape_skipped"` | enrollment | per-pipeline `event_alerts` |
| 8 | Memory pressure | `run.googleapis.com/container/memory/utilizations` > 85% | both | `modules/pipeline/alerts.tf` |
| 9 | Cost | BigQuery scanned bytes + optional billing budget | platform | `modules/platform/monitoring.tf` |

Runbook entries for each: [`02-runbook.md`](02-runbook.md).

## The thing everything else depends on

**Every alert here is downstream of the container exiting non-zero.** Both
source pipelines caught their exceptions, printed them, and exited 0. Deployed
as-is, all nine of these would be permanently green — which is worse than
having no monitoring, because it looks like coverage.

That is why `src/owcdata/errors.py` and
`tests/unit/test_exit_codes.py` matter more than any Terraform in this repo.

## Why alert 2 is a scheduled query and not metric absence

The obvious way to ask "did it run at all?" is Cloud Monitoring's metric
absence condition. **It caps at 23.5 hours.** That covers a daily job and
nothing else, and this system's cadences are monthly, quarterly, and yearly.

And a green Cloud Scheduler history proves nothing: `jobs:run` returns a
long-running Operation immediately, so Scheduler gets a 200 in milliseconds
regardless of what the job then does. Scheduler success and pipeline success
are unrelated facts.

So alert 2 is a **freshness dead-man's-switch**: a BigQuery scheduled query
that asserts every group has had a successful run inside its interval plus
grace, and calls `ERROR()` when one has not. The failure lands in Cloud
Logging, where a log metric and alert policy route it to the distribution
list.

| Group | Max interval | Grace | Threshold |
|---|---|---|---|
| lightcast monthly | 744h (31d) | 48h | 792h |
| lightcast quarterly | 2208h (92d) | 96h | 2304h |
| lightcast yearly | 8784h (366d) | 168h | 8952h |
| enrollment monthly | 744h | 72h | 816h |

Grace periods come from `freshness_grace_hours` in `pipelines.yml`.

**This alert is the only thing that notices a quarterly scheduler that quietly
stopped firing.** Nothing else in the system would.

**It depends entirely on `owc_ops.pipeline_runs` being written.** A
`manifest_write_failed` log line means the runs may be fine while the
record-keeping is broken — which disables this alert. That is why the manifest
writer logs at ERROR when it cannot write, and does not fail the run.

**Known gap:** a dataset that has *never* run successfully has no row in
`pipeline_runs` and therefore cannot be detected as stale. The freshness query
compares against what exists. For a brand-new dataset, confirm the first run
manually.

## Why alert 5 is separate from alert 4

Both come from `quality_check_failed`. Alert 5 narrows it:

```
jsonPayload.check="row_count_drift" OR jsonPayload.check="max_year_regressed"
```

It gets its own policy and its own runbook entry because it is the mitigation
for a **specific accepted risk**: `fact_regional_indicators.sql` pins
`YEAR = 2025/2024/2023` and the `*_idx` files pin a 2015 baseline. On a
schedule those eventually produce wrong-but-plausible numbers, which is the
worst failure mode available and which no null check would catch.

The alert is a smoke detector. The fix is editing the SQL — see
[the stale-year procedure](02-runbook.md#stale-year-literals).

## Why alert 6 has its own name

`no_source_files_found` is not a generic extract failure. It means the scraper
parsed Oklahoma's page successfully and found **zero** matching files, which is
the precise signature of the page having been redesigned. It is the most likely
failure this pipeline will ever have.

The original script printed `"No matching files were found on the page.
Nothing to do."` and returned normally.

Its runbook entry starts from the page snapshot rather than from the code,
because every run writes one to
`gs://<raw>/enrollment/page_snapshots/<run_id>.html` before parsing. A break
becomes a diff.

## Metric type strings

**Confirm every `metric.type` in Metrics Explorer before changing it.** A
typo'd metric type applies cleanly and then never fires — worse than no alert,
because the dashboard shows a policy that will never trigger.

Alert 1 uses `job/completed_task_attempt_count` with `result="failed"`, which
is a confirmed metric and label. `job/completed_execution_count` was not
verified and is deliberately not used.

To check a policy is actually wired to data:

```bash
gcloud monitoring policies list --project=$PROJECT \
  --format='table(displayName,enabled,conditions[].conditionThreshold.filter)'
```

## Log-based metrics and their event strings

The `event_alerts` variable on the pipeline module takes an `event` that must
match a `jsonPayload.event` the code actually emits. Those strings come from
the `event` attribute on the classes in `src/owcdata/errors.py` and from
`core/quality.py`.

They are duplicated between Python and Terraform, so
`tests/unit/test_exit_codes.py::test_alert_event_names_are_pinned` asserts the
exact values. Renaming one in Python without renaming it in Terraform silently
disables an alert; that test is what turns it into a test failure instead.

The metrics carry a `dataset` label extracted from `jsonPayload.dataset`, so
the alert email names which dataset was involved.

## The notification channel

One email channel per address in `alert_emails`, pointed at a **distribution
list**. People join and leave the rotation by being added to the list, not by
someone opening a Terraform PR.

If `alert_emails` is empty, every alert policy is skipped via `count`. That is
intentional for a scratch environment and is exactly wrong for prod — verify
after the first prod apply:

```bash
gcloud monitoring policies list --project=owc-data-prod --format='value(displayName)' | wc -l
# expect 9-ish; 0 means alert_emails was empty
```

## Verifying the alerts actually fire

Per the design: deliberately break things and confirm each one fires. Do this
in dev.

| Alert | How to trigger it |
|---|---|
| 1 | `gcloud run jobs execute okw-lightcast-dev --args="run,lightcast,--dataset,dim_area" --update-env-vars=SNOWFLAKE_PASSWORD=wrong` |
| 2 | Pause a scheduler and wait past the grace window — or temporarily lower `max_age_hours` to 1 and re-apply |
| 3 | Temporarily change the scheduler's `oauth_token` to an `oidc_token` by hand. Expect a 401. Revert with `terraform apply`. |
| 4 / 5 | Set `known_row_counts: {dim_area: 1}` in `pipelines.yml` and run `dim_area`. Confirm publish is blocked and `owc_marts.dim_area` is unchanged. |
| 6 | Point `page_url` at `tests/fixtures/enrollment/page_redesigned.html` served locally, or any page with no matching links. Confirm exit code 4. |
| 7 | Put a corrupt `.xlsx` in the state bucket's `data_sources/` under a name the page links |
| 8 | Lower `memory_utilization_threshold` to 0.01 and run anything |
| 9 | Lower `bigquery_scanned_bytes_threshold_gib` to 0 |

Record the date of the last verification somewhere durable. An alert nobody
has ever seen fire is an alert nobody knows works.

## The "is the data current?" table

`owc_ops.dataset_freshness` is a view over `pipeline_runs`: one row per
dataset, when it last succeeded, how many hours ago, its row count, its
`max_year`, and the git SHA that produced it.

It is the first thing to check for any alert, and it is what non-technical
stakeholders should be pointed at instead of asking someone to check Cloud
Run. See [`00-overview.md`](00-overview.md).
