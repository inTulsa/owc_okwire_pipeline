output "job_name" {
  value = google_cloud_run_v2_job.this.name
}

output "job_id" {
  value = google_cloud_run_v2_job.this.id
}

output "scheduler_job_names" {
  value       = { for k, j in google_cloud_scheduler_job.this : k => j.name }
  description = "One per schedule group. Pause one of these to test the freshness alert."
}

output "run_command" {
  value       = "gcloud run jobs execute ${google_cloud_run_v2_job.this.name} --region ${var.region} --project ${var.project_id}"
  description = "Manual trigger, for the runbook."
}

output "log_metric_names" {
  value       = { for k, m in google_logging_metric.event : k => m.name }
  description = "Log-based metrics backing this pipeline's event alerts."
}
