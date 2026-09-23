# What this system does

*Written for anyone who uses the dashboards. No technical background needed.*

## The short version

Two automated jobs collect data and put it somewhere PowerBI can read it.
They run on a schedule, they check their own work, and they email a
distribution list when something goes wrong.

| | **Lightcast** | **School enrollment** |
|---|---|---|
| Where the data comes from | Lightcast, a labor-market data vendor we license | The Oklahoma Department of Education's public website |
| What it contains | Job postings, employment, wages, graduates, skills — 41 separate tables | Public school enrollment by school, year, grade, race, and gender |
| How often it updates | Most tables monthly, on the 1st | Checked monthly, on the 5th |
| How often the *data* actually changes | Monthly to yearly, depending on the table | Roughly once a year, when the state publishes a new school year |

## "Is the data current?"

You do not need to ask anyone. There is a table that answers it:

```
owc_ops.dataset_freshness
```

And for "what ran recently, and did anything fail?", newest first:

```
owc_ops.pipeline_runs_recent
```

One row per table, showing when it last updated successfully, how many hours
ago that was, and how many rows it has. If a number on a dashboard looks
wrong, this is the first place to look — it will tell you whether the table is
stale or whether the number is just surprising.

## What the alert emails mean

Alerts go to a distribution list, so ask to be added or removed rather than
having someone edit code.

| Subject line contains | What it means | Does the dashboard still work? |
|---|---|---|
| **ALERT 1: task failed** | One table failed to update. | Yes — it shows the previous good data. That table is now stale. |
| **ALERT 2: a pipeline did not run** | A scheduled job stopped running entirely. | Yes, but the data is getting old. This one matters. |
| **ALERT 3: Scheduler is failing** | The system that starts the jobs is broken, so nothing is running. | Yes, but nothing is updating at all. |
| **ALERT 4: quality check failed** | New data looked wrong, so the system **refused to publish it**. | Yes — deliberately. It is showing the last data that passed its checks. |
| **ALERT 5: row count or max(YEAR) drifted** | A table's size or most recent year changed more than expected. | Yes. Often a real change in the data, sometimes a bug. Worth a look. |
| **ALERT 6: enrollment scrape found NOTHING** | The Oklahoma website changed and we can no longer find the files. | Yes, but enrollment data will not update until someone fixes it. |
| **ALERT 7: enrollment workbook was skipped** | One school year's spreadsheet could not be read. | Yes, but that year may be missing from the data. |
| **ALERT 8: memory** | A job is close to its resource limit. Early warning only. | Yes. |
| **ALERT 9: cost** | Cloud spending crossed a threshold. | Yes. Nothing is broken. |

The important thing to understand about alerts 4 and 5: **the system chooses to
publish nothing rather than publish something wrong.** A stale dashboard is a
recoverable problem; a dashboard full of plausible-looking bad numbers that
somebody acts on is not.

## "The dashboard looks wrong"

In order:

1. **Check `owc_ops.dataset_freshness`.** If the table is stale, the number is
   old, not wrong. Someone on the technical side should already have an alert
   email about it.
2. **Check whether an alert 4 or 5 email arrived recently.** If so, the system
   spotted the same thing you did and refused to publish. The number you are
   looking at is the last one that passed its checks.
3. **If the table is current and no alert fired,** the number is what the
   source data actually says. That is a question for whoever owns the
   underlying data, not for the pipeline.

## Two things worth knowing

**Some Lightcast queries have years written into them.** A handful — regional
indicators and the index tables — have specific years hardcoded rather than
computed. Nobody changed that, because rewriting working queries was
deliberately out of scope for this project. The system watches for the symptom
instead: if a table's row count or most recent year moves unexpectedly, alert
5 fires. That is a smoke detector, not a fix. At some point someone should
update those queries.

**The enrollment data comes from scraping a webpage we do not control.** When
the Oklahoma Department of Education redesigns that page — and eventually they
will — our system will stop finding the files and alert 6 will fire. This is
expected, not a surprise, and the runbook has a procedure for it. Every run
saves a copy of the page, so the fix starts from "what changed" rather than
from scratch.

## Who to ask

| About | Ask |
|---|---|
| A dashboard number | Whoever owns that dashboard |
| Data freshness or an alert email | The data platform on-call |
| The Lightcast relationship, license, or their bill | The Lightcast account owner at Tulsa For You |
| The Oklahoma enrollment data itself | Oklahoma State Department of Education |

Technical documentation starts at [`architecture.md`](architecture.md).
The enrollment pipeline's original business-process write-ups are preserved in
[`enrollment/`](enrollment/).
