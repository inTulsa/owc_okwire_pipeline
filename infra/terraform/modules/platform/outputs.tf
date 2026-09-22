output "raw_bucket" {
  value       = google_storage_bucket.raw.name
  description = "Parquet, archived Excel originals, page snapshots. Prefixed per pipeline."
}

output "enrollment_state_bucket" {
  value       = google_storage_bucket.enrollment_state.name
  description = "FUSE-mounted scraper cache. No lifecycle deletion."
}

output "service_account_emails" {
  value = {
    lightcast  = google_service_account.lightcast.email
    enrollment = google_service_account.enrollment.email
    scheduler  = google_service_account.scheduler.email
    powerbi    = google_service_account.powerbi.email
    build      = google_service_account.build.email
    freshness  = google_service_account.freshness.email
  }
  description = "Runtime identities. One per pipeline, plus scheduler, PowerBI, and the freshness check."
}

output "datasets" {
  value = {
    staging = google_bigquery_dataset.staging.dataset_id
    marts   = google_bigquery_dataset.marts.dataset_id
    ops     = google_bigquery_dataset.ops.dataset_id
  }
}

output "snowflake_secret_id" {
  value       = google_secret_manager_secret.snowflake_password.secret_id
  description = "Set the value out of band; it is not in Terraform state."
}

output "image_repository" {
  value       = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Prefix for the container image. Terraform pins by digest, not tag."
}

output "notification_channels" {
  value       = local.notification_channels
  description = "Passed into each pipeline module so all alerts share one channel set."
}

output "location" {
  value       = var.location
  description = "Region co-location is mandatory — pipelines must use this same value."
}

output "image_repository_id" {
  value       = google_artifact_registry_repository.images.repository_id
  description = "Artifact Registry repository name alone. The wif module grants the deployer writer on it, so it must not be hardcoded alongside the naming convention."
}
