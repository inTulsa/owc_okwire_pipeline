# ---------------------------------------------------------------------------
# One runtime service account per pipeline, not one shared.
#
# The scraper has no business holding the Snowflake secret, and the Lightcast
# job has no business writing the scrape cache. Every grant below is scoped to
# a specific resource — bucket prefix, one secret, one dataset — rather than
# granted project-wide, which is what makes that separation real rather than
# aspirational.
# ---------------------------------------------------------------------------

resource "google_service_account" "lightcast" {
  account_id   = "okw-lightcast-${var.env}"
  project      = var.project_id
  display_name = "OWC lightcast pipeline (${var.env})"
  description  = "Runs the lightcast Cloud Run job. Holds the Snowflake secret."
  depends_on   = [google_project_service.enabled]
}

resource "google_service_account" "enrollment" {
  account_id   = "okw-enrollment-${var.env}"
  project      = var.project_id
  display_name = "OWC enrollment pipeline (${var.env})"
  description  = "Runs the enrollment Cloud Run job. No secret access: the source is a public webpage."
  depends_on   = [google_project_service.enabled]
}

resource "google_service_account" "scheduler" {
  account_id   = "okw-scheduler-${var.env}"
  project      = var.project_id
  display_name = "OWC Cloud Scheduler invoker (${var.env})"
  description  = "Invokes the Cloud Run jobs. run.invoker on the specific jobs only."
  depends_on   = [google_project_service.enabled]
}

resource "google_service_account" "powerbi" {
  account_id   = "okw-powerbi-${var.env}"
  project      = var.project_id
  display_name = "OWC PowerBI reader (${var.env})"
  description  = "Reads owc_reporting ONLY. See docs/01-architecture.md ADR-006 for the JSON-key exception."
  depends_on   = [google_project_service.enabled]
}

# ---------------------------------------------------------------------------
# Storage: each pipeline gets objectAdmin on its OWN prefix.
#
# IAM conditions on resource.name are how a prefix grant is expressed; there
# is no per-prefix ACL. Both conditions also allow bucket-level list, which
# the client needs to resolve a prefix at all.
# ---------------------------------------------------------------------------
resource "google_storage_bucket_iam_member" "lightcast_raw_prefix" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.lightcast.email}"

  condition {
    title       = "lightcast prefix only"
    description = "Objects under lightcast/ in this bucket"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.raw.name}/objects/lightcast/\")"
  }
}

resource "google_storage_bucket_iam_member" "enrollment_raw_prefix" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.enrollment.email}"

  condition {
    title       = "enrollment prefix only"
    description = "Objects under enrollment/ in this bucket"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.raw.name}/objects/enrollment/\")"
  }
}

# Both need to list the bucket to resolve their prefix. Legacy reader is the
# narrowest role that grants storage.objects.list without object read on
# objects outside the conditional grants above.
resource "google_storage_bucket_iam_member" "raw_list" {
  for_each = {
    lightcast  = google_service_account.lightcast.email
    enrollment = google_service_account.enrollment.email
  }
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${each.value}"
}

# Only enrollment touches the state bucket, and it needs full object access
# across the whole bucket because that is where FUSE reads and writes the
# cache. lightcast gets nothing here at all.
resource "google_storage_bucket_iam_member" "enrollment_state" {
  bucket = google_storage_bucket.enrollment_state.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.enrollment.email}"
}

resource "google_storage_bucket_iam_member" "enrollment_state_list" {
  bucket = google_storage_bucket.enrollment_state.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.enrollment.email}"
}

# ---------------------------------------------------------------------------
# BigQuery: dataEditor on staging + marts + ops, jobUser at project level.
#
# jobUser has to be project-level — running a query job is a project
# permission, not a dataset one. dataEditor is per dataset, which is where the
# actual containment is.
# ---------------------------------------------------------------------------
locals {
  pipeline_sa_emails = {
    lightcast  = google_service_account.lightcast.email
    enrollment = google_service_account.enrollment.email
  }
  writable_datasets = {
    staging = google_bigquery_dataset.staging.dataset_id
    marts   = google_bigquery_dataset.marts.dataset_id
    ops     = google_bigquery_dataset.ops.dataset_id
  }
  # One entry per (pipeline, dataset) pair.
  dataset_grants = {
    for pair in setproduct(keys(local.pipeline_sa_emails), keys(local.writable_datasets)) :
    "${pair[0]}-${pair[1]}" => {
      email   = local.pipeline_sa_emails[pair[0]]
      dataset = local.writable_datasets[pair[1]]
    }
  }
}

resource "google_bigquery_dataset_iam_member" "pipeline_data_editor" {
  for_each = local.dataset_grants

  project    = var.project_id
  dataset_id = each.value.dataset
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${each.value.email}"
}

# The pipeline creates the authorized views in reporting at publish time, so
# it needs to be able to create a view there.
resource "google_bigquery_dataset_iam_member" "pipeline_reporting_editor" {
  for_each = local.pipeline_sa_emails

  project    = var.project_id
  dataset_id = google_bigquery_dataset.reporting.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "pipeline_job_user" {
  for_each = local.pipeline_sa_emails

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${each.value}"
}

# ---------------------------------------------------------------------------
# PowerBI: dataViewer on owc_reporting ONLY, and jobUser so it can run a
# query. Deliberately NO grant on owc_marts — the authorized views read marts
# on their own authority. If this ever grows a marts grant, the three-dataset
# split has stopped doing its job.
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset_iam_member" "powerbi_reporting" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.reporting.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.powerbi.email}"
}

resource "google_project_iam_member" "powerbi_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.powerbi.email}"
}

# ---------------------------------------------------------------------------
# Logging and metrics for both pipelines. Without logWriter the structured
# logs never arrive, and every log-based alert is silently dead.
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "pipeline_log_writer" {
  for_each = local.pipeline_sa_emails

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "pipeline_metric_writer" {
  for_each = local.pipeline_sa_emails

  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${each.value}"
}
