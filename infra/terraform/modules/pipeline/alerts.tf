locals {
  alerts_enabled = length(var.notification_channels) > 0
}

# ---------------------------------------------------------------------------
# ALERT 1: a task failed.
#
# Uses run.googleapis.com/job/completed_task_attempt_count with
# result="failed" — a confirmed metric and label. This is the alert that
# depends entirely on the container exiting non-zero, which is why the exit
# codes in src/owcdata/errors.py are the product and not a detail.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "task_failed" {
  count = local.alerts_enabled ? 1 : 0

  project      = var.project_id
  display_name = "[${var.env}] ALERT 1: ${var.name} task failed"
  combiner     = "OR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      A `${var.name}` Cloud Run task exited non-zero after exhausting its
      ${var.max_retries} retries.

      The exit code names the cause — see the table in
      `docs/runbook.md#exit-codes`. The structured log line carries
      `event`, `dataset`, and `error`.

      Runbook: `docs/runbook.md#alert-1-task-failed`.
    EOT
  }

  conditions {
    display_name = "failed task attempts > 0"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"run.googleapis.com/job/completed_task_attempt_count\"",
        "resource.type=\"cloud_run_job\"",
        "resource.label.\"job_name\"=\"${google_cloud_run_v2_job.this.name}\"",
        "metric.label.\"result\"=\"failed\"",
      ])
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

  notification_channels = var.notification_channels
  alert_strategy {
    auto_close = "86400s"
  }
}

# ---------------------------------------------------------------------------
# ALERTS 4 / 5 / 6 / 7: log-based, one per declared event.
#
# Each pipeline declares which of its structured-log events deserve an alert,
# which is what keeps this module generic. The event strings come from
# src/owcdata/errors.py and core/quality.py and are pinned by
# tests/unit/test_exit_codes.py, because a typo'd event string applies cleanly
# and then never fires.
# ---------------------------------------------------------------------------
resource "google_logging_metric" "event" {
  for_each = { for a in var.event_alerts : a.key => a }

  name    = "owc/${var.env}/${var.name}/${each.value.key}"
  project = var.project_id

  filter = join("\n", compact([
    "resource.type=\"cloud_run_job\"",
    "resource.labels.job_name=\"${google_cloud_run_v2_job.this.name}\"",
    "jsonPayload.event=\"${each.value.event}\"",
    each.value.extra_filter,
  ]))

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "dataset"
      value_type  = "STRING"
      description = "Which dataset produced the event"
    }
  }

  label_extractors = {
    dataset = "EXTRACT(jsonPayload.dataset)"
  }
}

# Wait for the metrics above to become queryable from Monitoring.
#
# `triggers` keyed on the metric ids means this is recreated — and therefore
# waits again — whenever the set of metrics changes. Without that, adding an
# event alert later would race exactly as the first apply did.
resource "time_sleep" "metric_propagation" {
  count = length(var.event_alerts) > 0 ? 1 : 0

  create_duration = var.metric_propagation_wait

  triggers = {
    metrics = join(",", sort([for m in google_logging_metric.event : m.id]))
  }

  depends_on = [google_logging_metric.event]
}

resource "google_monitoring_alert_policy" "event" {
  for_each = local.alerts_enabled ? { for a in var.event_alerts : a.key => a } : {}

  project      = var.project_id
  display_name = "[${var.env}] ${each.value.title}"
  combiner     = "OR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      ${each.value.description}

      Log query:
      ```
      resource.type="cloud_run_job"
      resource.labels.job_name="${google_cloud_run_v2_job.this.name}"
      jsonPayload.event="${each.value.event}"
      ```

      Runbook: `docs/runbook.md#${each.value.key}`.
    EOT
  }

  conditions {
    display_name = "${each.value.event} logged"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/owc/${var.env}/${var.name}/${each.value.key}\" AND resource.type=\"cloud_run_job\""
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

  notification_channels = var.notification_channels
  alert_strategy {
    auto_close = "86400s"
  }

  depends_on = [time_sleep.metric_propagation]
}

# ---------------------------------------------------------------------------
# ALERT 8: memory pressure.
#
# Early warning before an OOM kill. The Parquet writer streams, so a task
# creeping toward its limit means either a result shape changed or something
# is buffering that should not be.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "memory_pressure" {
  count = local.alerts_enabled ? 1 : 0

  project      = var.project_id
  display_name = "[${var.env}] ALERT 8: ${var.name} memory above ${floor(var.memory_utilization_threshold * 100)}%"
  combiner     = "OR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      A `${var.name}` task used more than
      ${floor(var.memory_utilization_threshold * 100)}% of its ${var.memory}
      limit. Cloud Run kills the instance at 100% with no graceful failure, so
      this is the warning that comes before a crash that is harder to read.

      The Parquet writer's peak is bounded by `ROW_GROUP_TARGET_BYTES` in
      `src/owcdata/pipelines/lightcast/run.py`, measured at ~290 MB. A task
      approaching 2 GiB means something is buffering that should be streaming.

      Runbook: `docs/runbook.md#alert-8-memory`.
    EOT
  }

  conditions {
    display_name = "container memory utilization"
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"run.googleapis.com/container/memory/utilizations\"",
        "resource.type=\"cloud_run_job\"",
        "resource.label.\"job_name\"=\"${google_cloud_run_v2_job.this.name}\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = var.memory_utilization_threshold
      duration        = "60s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }

  notification_channels = var.notification_channels
  alert_strategy {
    auto_close = "86400s"
  }
}
