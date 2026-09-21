# ---------------------------------------------------------------------------
# Four datasets, all co-located with the raw bucket.
#
#   staging   load target, short-lived
#   marts     published tables
#   reporting authorized views — PowerBI's ONLY entry point
#   ops       run manifest and pre-publish snapshots
#
# The split exists so PowerBI can read the data without holding any grant on
# owc_marts. That is what authorized views buy, and wiring them is the step
# most often forgotten.
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset" "staging" {
  dataset_id  = "owc_staging"
  project     = var.project_id
  location    = var.location
  labels      = var.labels
  description = "Load target. Quality checks run here before publish; a failed check leaves the data in place to diff."

  # Staging is diffing material after a failure, not a permanent store.
  default_table_expiration_ms = var.staging_table_expiration_days * 24 * 60 * 60 * 1000

  depends_on = [google_project_service.enabled]
}

resource "google_bigquery_dataset" "marts" {
  dataset_id  = "owc_marts"
  project     = var.project_id
  location    = var.location
  labels      = var.labels
  description = "Published tables. Unpartitioned by design — see docs/01-architecture.md ADR-002."

  # Access entries are managed outside Terraform: the pipeline adds one
  # authorized-view entry per published table at publish time, and Terraform
  # would fight it on every apply.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [access]
  }

  depends_on = [google_project_service.enabled]
}

resource "google_bigquery_dataset" "reporting" {
  dataset_id  = "owc_reporting"
  project     = var.project_id
  location    = var.location
  labels      = var.labels
  description = "Authorized views only. PowerBI's sole entry point; holds no data of its own."

  depends_on = [google_project_service.enabled]
}

resource "google_bigquery_dataset" "ops" {
  dataset_id  = "owc_ops"
  project     = var.project_id
  location    = var.location
  labels      = var.labels
  description = "pipeline_runs manifest and pre-publish table snapshots."

  depends_on = [google_project_service.enabled]
}

# ---------------------------------------------------------------------------
# pipeline_runs: one row per dataset per run.
#
# Powers the freshness alert, gives the quality gate its prior-run baseline,
# and doubles as an "is the data current?" page for non-technical
# stakeholders. Schema mirrors src/owcdata/core/manifest.py SCHEMA.
# ---------------------------------------------------------------------------
resource "google_bigquery_table" "pipeline_runs" {
  dataset_id          = google_bigquery_dataset.ops.dataset_id
  table_id            = "pipeline_runs"
  project             = var.project_id
  labels              = var.labels
  deletion_protection = true

  # Partitioned because this table IS queried by time, on every freshness
  # check, forever. Unlike the marts tables, where the design says don't.
  time_partitioning {
    type  = "DAY"
    field = "started_at"
  }
  clustering = ["pipeline", "dataset"]

  schema = jsonencode([
    { name = "run_id", type = "STRING", mode = "REQUIRED", description = "Cloud Run execution name, shared by every task in one execution" },
    { name = "pipeline", type = "STRING", mode = "REQUIRED" },
    { name = "dataset", type = "STRING", mode = "REQUIRED" },
    { name = "group_name", type = "STRING", mode = "NULLABLE", description = "Schedule group: monthly, quarterly, yearly" },
    { name = "status", type = "STRING", mode = "REQUIRED", description = "success | success_no_change | failed | running" },
    { name = "row_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "bytes", type = "INTEGER", mode = "NULLABLE" },
    { name = "max_year", type = "INTEGER", mode = "NULLABLE", description = "max(YEAR) in this run; the baseline for the stale-year-literal alert" },
    { name = "source_query_id", type = "STRING", mode = "NULLABLE", description = "Snowflake query id, for looking a slow extract up in their history" },
    { name = "source_uri", type = "STRING", mode = "NULLABLE" },
    { name = "started_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "finished_at", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "duration_seconds", type = "FLOAT", mode = "NULLABLE" },
    { name = "git_sha", type = "STRING", mode = "NULLABLE" },
    { name = "env", type = "STRING", mode = "NULLABLE" },
    { name = "error", type = "STRING", mode = "NULLABLE" },
  ])
}

# A ready-made "is the data current?" view for stakeholders who should not
# have to write SQL to find out.
resource "google_bigquery_table" "dataset_freshness" {
  dataset_id          = google_bigquery_dataset.ops.dataset_id
  table_id            = "dataset_freshness"
  project             = var.project_id
  labels              = var.labels
  deletion_protection = false

  view {
    use_legacy_sql = false
    query          = <<-SQL
      -- Latest successful run per dataset, with how stale it is.
      SELECT
        pipeline,
        dataset,
        ANY_VALUE(group_name)                               AS schedule_group,
        MAX(finished_at)                                    AS last_success_at,
        TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(finished_at), HOUR) AS hours_since_success,
        ANY_VALUE(row_count  HAVING MAX finished_at)        AS last_row_count,
        ANY_VALUE(max_year   HAVING MAX finished_at)        AS last_max_year,
        ANY_VALUE(git_sha    HAVING MAX finished_at)        AS last_git_sha
      FROM `${var.project_id}.owc_ops.pipeline_runs`
      WHERE status IN ('success', 'success_no_change')
      GROUP BY pipeline, dataset
      ORDER BY hours_since_success DESC
    SQL
  }

  depends_on = [google_bigquery_table.pipeline_runs]
}
