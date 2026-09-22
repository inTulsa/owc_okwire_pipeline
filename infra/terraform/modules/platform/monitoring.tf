# ---------------------------------------------------------------------------
# Notification channel.
#
# One channel per address, pointed at a DISTRIBUTION LIST so people can join
# and leave the rotation without a Terraform change.
# ---------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.alert_emails)

  project      = var.project_id
  display_name = "OWC ${var.env} alerts -> ${each.value}"
  type         = "email"
  labels = {
    email_address = each.value
  }

  depends_on = [google_project_service.enabled]
}

locals {
  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]
}

# ---------------------------------------------------------------------------
# ALERT 2: "Didn't run at all" — the freshness dead-man's-switch.
#
# A green Cloud Scheduler history means nothing: jobs:run returns a
# long-running Operation immediately, so Scheduler gets a 200 in milliseconds
# regardless of what the job then does. And metric absence caps at 23.5h,
# which does not cover monthly/quarterly/yearly.
#
# So: a scheduled query that FAILS when any group is stale. The failure lands
# in Cloud Logging, where the log metric and alert policy below pick it up and
# route it to the distribution list.
# ---------------------------------------------------------------------------
resource "google_service_account" "freshness" {
  account_id   = local.name.sa_freshness
  project      = var.project_id
  display_name = "OWC freshness check (${var.env})"
  description  = "Runs the owc_ops.pipeline_runs freshness scheduled query. Read-only."
  depends_on   = [google_project_service.enabled]
}

resource "google_bigquery_dataset_iam_member" "freshness_reader" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.ops.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.freshness.email}"
}

resource "google_project_iam_member" "freshness_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.freshness.email}"
}

# Provision the BigQuery Data Transfer Service agent.
#
# Enabling an API does not create its service agent — the agent is created the
# first time the service is actually used. So constructing the address by hand
# and granting a role to it immediately after enabling the API fails with
# "service-<num>@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com does not
# exist". This forces it into existence and hands back its real email, which
# is also safer than string-building the address ourselves.
resource "google_project_service_identity" "bigquerydatatransfer" {
  provider = google-beta

  project = var.project_id
  service = "bigquerydatatransfer.googleapis.com"

  depends_on = [google_project_service.enabled]
}

# The Data Transfer Service mints tokens for the freshness SA when it runs the
# scheduled query, so its agent needs tokenCreator on that SA.
resource "google_service_account_iam_member" "freshness_token_creator" {
  service_account_id = google_service_account.freshness.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_project_service_identity.bigquerydatatransfer.member
}

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # Inlined as a UNNEST literal so the whole check is one query with no extra
  # table to keep in sync.
  freshness_threshold_struct = join(",\n        ", [
    for t in var.freshness_thresholds :
    "STRUCT('${t.pipeline}' AS pipeline, '${t.group_name}' AS group_name, ${t.max_age_hours} AS max_age_hours)"
  ])

  freshness_query = <<-SQL
    -- Fails when any schedule group has not had a successful run inside its
    -- own interval plus grace. A failure here is alert #2.
    WITH latest AS (
      SELECT
        pipeline,
        dataset,
        group_name,
        MAX(finished_at) AS last_success_at
      FROM `${var.project_id}.owc_ops.pipeline_runs`
      WHERE status IN ('success', 'success_no_change')
      GROUP BY pipeline, dataset, group_name
    ),
    thresholds AS (
      SELECT * FROM UNNEST([
        ${local.freshness_threshold_struct}
      ])
    ),
    stale AS (
      SELECT
        l.pipeline,
        l.dataset,
        l.group_name,
        TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), l.last_success_at, HOUR) AS age_hours,
        t.max_age_hours
      FROM latest AS l
      JOIN thresholds AS t
        ON l.pipeline = t.pipeline AND l.group_name = t.group_name
      WHERE TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), l.last_success_at, HOUR) > t.max_age_hours
    )
    SELECT
      IF(
        COUNT(*) = 0,
        'ok',
        ERROR(FORMAT(
          'PIPELINE FRESHNESS FAILURE: %d dataset(s) overdue: %s',
          COUNT(*),
          STRING_AGG(FORMAT('%s.%s (%s) %d h old, limit %d h',
                            pipeline, dataset, group_name, age_hours, max_age_hours),
                     '; ' ORDER BY age_hours DESC LIMIT 20)
        ))
      ) AS status
    FROM stale
  SQL
}

resource "google_bigquery_data_transfer_config" "freshness_check" {
  # Off in dev, where nothing runs on a schedule to be fresh. See the
  # variable's documentation.
  count = var.freshness_check_enabled ? 1 : 0

  project              = var.project_id
  location             = var.location
  display_name         = "OWC pipeline freshness check (${var.env})"
  data_source_id       = "scheduled_query"
  schedule             = var.freshness_check_schedule
  service_account_name = google_service_account.freshness.email

  params = {
    query = local.freshness_query
  }

  email_preferences {
    enable_failure_email = true
  }

  depends_on = [
    google_bigquery_table.pipeline_runs,
    google_service_account_iam_member.freshness_token_creator,
    google_project_iam_member.freshness_job_user,
  ]
}

resource "google_logging_metric" "freshness_failed" {
  name    = "owc/${var.env}/freshness_check_failed"
  project = var.project_id
  filter  = <<-EOT
    resource.type="bigquery_dts_config"
    severity>=ERROR
    protoPayload.serviceName="bigquerydatatransfer.googleapis.com" OR textPayload:"PIPELINE FRESHNESS FAILURE"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.enabled]
}

# See the pipeline module's time_sleep for why elapsed time is required here.
resource "time_sleep" "platform_metric_propagation" {
  create_duration = var.metric_propagation_wait

  triggers = {
    metrics = join(",", [
      google_logging_metric.freshness_failed.id,
      google_logging_metric.scheduler_error.id,
    ])
  }

  depends_on = [
    google_logging_metric.freshness_failed,
    google_logging_metric.scheduler_error,
  ]
}

resource "google_monitoring_alert_policy" "didnt_run" {
  # Needs both an alert destination AND a freshness query to alert on.
  count = var.freshness_check_enabled && length(var.alert_emails) > 0 ? 1 : 0

  depends_on = [time_sleep.platform_metric_propagation]

  project      = var.project_id
  display_name = "[${var.env}] ALERT 2: a pipeline did not run (freshness)"
  combiner     = "OR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      A schedule group has no successful run inside its interval plus grace.

      **This is the only alert that catches a scheduler which quietly stopped
      firing.** A green Cloud Scheduler history proves nothing — `jobs:run`
      returns an Operation immediately and Scheduler gets a 200 in
      milliseconds whatever the job then does.

      Which dataset and how overdue is in the scheduled query's error message.
      Runbook: `docs/02-runbook.md#alert-2-didnt-run`.
    EOT
  }

  conditions {
    display_name = "freshness check failed"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.freshness_failed.name}\" AND resource.type=\"bigquery_dts_config\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.notification_channels
  alert_strategy {
    auto_close = "86400s"
  }
}

# ---------------------------------------------------------------------------
# ALERT 3: Cloud Scheduler itself failing.
#
# Catches an auth failure where the job never starts — so no Cloud Run metric
# is ever emitted and alert #1 has nothing to fire on.
# ---------------------------------------------------------------------------
resource "google_logging_metric" "scheduler_error" {
  name    = "owc/${var.env}/scheduler_error"
  project = var.project_id
  filter  = <<-EOT
    resource.type="cloud_scheduler_job"
    severity>=ERROR
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_service.enabled]
}

resource "google_monitoring_alert_policy" "scheduler_failing" {
  count = length(var.alert_emails) > 0 ? 1 : 0

  depends_on = [time_sleep.platform_metric_propagation]

  project      = var.project_id
  display_name = "[${var.env}] ALERT 3: Cloud Scheduler is failing to invoke a job"
  combiner     = "OR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud Scheduler logged an error invoking a Cloud Run job. The job never
      started, so no Cloud Run task metric exists and alert #1 will not fire.

      The usual cause is the token type: calling `run.googleapis.com` needs an
      **oauth_token** with scope `cloud-platform`. An `oidc_token` produces a
      401 here and is the classic misconfiguration for this pattern.

      Runbook: `docs/02-runbook.md#alert-3-scheduler-failing`.
    EOT
  }

  conditions {
    display_name = "scheduler error logged"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.scheduler_error.name}\" AND resource.type=\"cloud_scheduler_job\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
      trigger { count = 1 }
    }
  }

  notification_channels = local.notification_channels
  alert_strategy {
    auto_close = "86400s"
  }
}

# ---------------------------------------------------------------------------
# ALERT 9: Cost.
#
# BigQuery scanned bytes, plus an optional billing budget. The scanned-bytes
# one matters most if PowerBI lands on DirectQuery, which bills a scan per
# slicer click.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "bigquery_scanned_bytes" {
  count = length(var.alert_emails) > 0 ? 1 : 0

  project      = var.project_id
  display_name = "[${var.env}] ALERT 9: BigQuery scanned bytes above ${var.bigquery_scanned_bytes_threshold_gib} GiB/day"
  combiner     = "OR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Daily BigQuery scanned bytes crossed the threshold. The pipeline itself
      scans very little — loads and table copies are free, and the quality
      gate is one scan of staging per dataset — so this is almost always a
      reporting query pattern.

      If PowerBI is on DirectQuery, add a custom daily query quota as well.
      Runbook: `docs/02-runbook.md#alert-9-cost`.
    EOT
  }

  conditions {
    display_name = "scanned bytes billed per day"
    condition_threshold {
      # VERIFIED against this project's metricDescriptors, not assumed:
      # query/scanned_bytes_billed is reported against the "global" monitored
      # resource, NOT "bigquery_project". Pairing it with bigquery_project is
      # rejected at create time with "does not specify a valid combination of
      # metric and monitored resource descriptors".
      #   bigquery.googleapis.com/query/scanned_bytes          -> global
      #   bigquery.googleapis.com/query/scanned_bytes_billed   -> global
      #   bigquery.googleapis.com/query/statement_scanned_bytes -> bigquery_project
      # "billed" is the cost-relevant number: it includes the per-table 10 MB
      # minimum, which is what actually appears on the invoice.
      filter          = "metric.type=\"bigquery.googleapis.com/query/scanned_bytes_billed\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.bigquery_scanned_bytes_threshold_gib * 1024 * 1024 * 1024
      duration        = "0s"
      aggregations {
        alignment_period   = "86400s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.notification_channels
  alert_strategy {
    auto_close = "604800s"
  }
}

resource "google_billing_budget" "monthly" {
  count = var.billing_budget_amount > 0 && var.billing_account != "" ? 1 : 0

  billing_account = var.billing_account
  display_name    = "OWC data platform (${var.env})"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.billing_budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    monitoring_notification_channels = local.notification_channels
    disable_default_iam_recipients   = false
  }
}
