# ---------------------------------------------------------------------------
# One Cloud Scheduler job per schedule entry.
#
# Two things here are easy to get wrong and both fail silently-ish:
#
#   oauth_token, NOT oidc_token. Calling run.googleapis.com requires an OAuth2
#   token with scope cloud-platform. OIDC is for your own endpoints and
#   produces the classic 401 on this pattern.
#
#   retry_count = 0. jobs:run is NOT idempotent: a transient 503 with retries
#   enabled can start two executions for one run_date, which for lightcast
#   means re-querying and re-billing Lightcast's warehouse twice.
# ---------------------------------------------------------------------------
resource "google_cloud_scheduler_job" "this" {
  for_each = { for s in var.schedules : s.name => s }

  name        = "okw-${var.name}-${each.value.name}-${var.env}"
  project     = var.project_id
  region      = var.region
  schedule    = each.value.cron
  time_zone   = var.timezone
  description = "Runs the ${var.name} pipeline (${each.value.name} group)."

  # jobs:run is not idempotent — see the header comment.
  retry_config {
    retry_count = 0
  }

  # A long-running Operation comes back in milliseconds, so this only needs to
  # cover the API call itself, not the pipeline run.
  attempt_deadline = "180s"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.project_id}/jobs/${google_cloud_run_v2_job.this.name}:run"

    headers = {
      "Content-Type" = "application/json"
    }

    # Overrides let all of a pipeline's groups share one job definition and
    # differ only in the arguments and task count the scheduler asks for.
    # One dataset per task, so a retry re-runs only the query that failed
    # rather than re-billing Lightcast for the ones that already succeeded.
    body = base64encode(jsonencode({
      overrides = {
        containerOverrides = [{
          args = concat(["run", var.name], each.value.args)
        }]
        taskCount = each.value.task_count
      }
    }))

    oauth_token {
      service_account_email = var.scheduler_service_account_email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoker]
}
