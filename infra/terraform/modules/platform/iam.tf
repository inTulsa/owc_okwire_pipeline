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
  # Created by infra/gcloud/01-admin-identities.sh when
  # manage_identities is false. See that variable.
  count = var.manage_identities ? 1 : 0

  account_id   = local.name.sa_lightcast
  project      = var.project_id
  display_name = "OWC lightcast pipeline (${var.env})"
  description  = "Runs the lightcast Cloud Run job. Holds the Snowflake secret."
  depends_on   = [google_project_service.enabled]
}

resource "google_service_account" "enrollment" {
  # Created by infra/gcloud/01-admin-identities.sh when
  # manage_identities is false. See that variable.
  count = var.manage_identities ? 1 : 0

  account_id   = local.name.sa_enrollment
  project      = var.project_id
  display_name = "OWC enrollment pipeline (${var.env})"
  description  = "Runs the enrollment Cloud Run job. No secret access: the source is a public webpage."
  depends_on   = [google_project_service.enabled]
}

resource "google_service_account" "scheduler" {
  # Created by infra/gcloud/01-admin-identities.sh when
  # manage_identities is false. See that variable.
  count = var.manage_identities ? 1 : 0

  account_id   = local.name.sa_scheduler
  project      = var.project_id
  display_name = "OWC Cloud Scheduler invoker (${var.env})"
  description  = "Invokes the Cloud Run jobs. run.invoker on the specific jobs only."
  depends_on   = [google_project_service.enabled]
}

# ---------------------------------------------------------------------------
# Cloud Build's identity.
#
# Without an explicit service account, Cloud Build runs builds as the
# **Compute Engine default** SA, which carries project Editor. Submitting a
# build then requires iam.serviceAccountUser on that SA — so the deployer
# would gain actAs on an Editor-privileged identity, which is a privilege
# escalation path dressed up as a CI fix. The failure was:
#
#   PERMISSION_DENIED: caller does not have permission to act as service
#   account projects/<p>/serviceAccounts/<compute-default-unique-id>
#
# So the build gets its own identity with only what a build needs, named in
# docker/cloudbuild.yaml via the _BUILD_SA substitution. Specifying a service
# account also requires options.logging to be CLOUD_LOGGING_ONLY, which that
# file already sets.
# ---------------------------------------------------------------------------
resource "google_service_account" "build" {
  # Created by infra/gcloud/01-admin-identities.sh when
  # manage_identities is false. See that variable.
  count = var.manage_identities ? 1 : 0

  account_id   = local.name.sa_build
  project      = var.project_id
  display_name = "OWC Cloud Build (${var.env})"
  description  = "Runs container builds. Reads build source, writes the image and logs. Nothing else."
  depends_on   = [google_project_service.enabled]
}

# Required when a build specifies its own service account.
resource "google_project_iam_member" "build_log_writer" {
  count = var.manage_identities ? 1 : 0

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.sa_email.build}"
}

# Reads the uploaded source tarball from gs://<project>_cloudbuild.
#
# Project-level rather than scoped to that bucket on purpose: the bucket is
# created by `gcloud builds submit` itself, so a bucket-scoped grant cannot
# exist before the first build. This is read-only on objects, held by an
# identity only the deployer can assume, and the deployer already has
# storage.admin — so it widens nothing in practice.
resource "google_project_iam_member" "build_source_reader" {
  count = var.manage_identities ? 1 : 0

  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${local.sa_email.build}"
}

resource "google_artifact_registry_repository_iam_member" "build_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.sa_email.build}"
}

resource "google_service_account" "powerbi" {
  # Created by infra/gcloud/01-admin-identities.sh when
  # manage_identities is false. See that variable.
  count = var.manage_identities ? 1 : 0

  account_id   = local.name.sa_powerbi
  project      = var.project_id
  display_name = "OWC PowerBI reader (${var.env})"
  description  = "Read-only on owc_marts. See docs/01-architecture.md ADR-006 for the JSON-key exception."
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
  member = "serviceAccount:${local.sa_email.lightcast}"

  condition {
    title       = "lightcast prefix only"
    description = "Objects under lightcast/ in this bucket"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.raw.name}/objects/lightcast/\")"
  }
}

resource "google_storage_bucket_iam_member" "enrollment_raw_prefix" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.sa_email.enrollment}"

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
    lightcast  = local.sa_email.lightcast
    enrollment = local.sa_email.enrollment
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
  member = "serviceAccount:${local.sa_email.enrollment}"
}

resource "google_storage_bucket_iam_member" "enrollment_state_list" {
  bucket = google_storage_bucket.enrollment_state.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${local.sa_email.enrollment}"
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
    lightcast  = local.sa_email.lightcast
    enrollment = local.sa_email.enrollment
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

# dataEditor + jobUser is the WHOLE permission set either pipeline needs.
#
# Two earlier designs each added a step requiring a permission this predefined
# role omits, and each forced a custom role:
#
#   * a pass-through authorized view      needed bigquery.datasets.update
#   * a pre-publish table snapshot        needed bigquery.tables.deleteSnapshot
#
# Both are gone (ADR-009, ADR-010). Rollback reloads the previous run's
# Parquet from GCS, which is an ordinary load job. There are no custom roles
# in this project, and a change that needs one should be treated as a prompt
# to find the design that does not.
resource "google_bigquery_dataset_iam_member" "pipeline_data_editor" {
  for_each = local.dataset_grants

  project    = var.project_id
  dataset_id = each.value.dataset
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${each.value.email}"
}

resource "google_project_iam_member" "pipeline_job_user" {
  for_each = var.manage_identities ? local.pipeline_sa_emails : {}

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${each.value}"
}

# ---------------------------------------------------------------------------
# PowerBI: read-only on owc_marts, plus jobUser so it can run a query.
#
# dataViewer, never dataEditor: PowerBI must not be able to write, and this is
# the identity behind a service-account JSON key (ADR-006), so its blast
# radius if that key leaks is exactly "can read the published tables".
#
# It gets nothing on owc_staging (unvalidated data) or owc_ops (run manifest
# which is the run manifest).
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset_iam_member" "powerbi_marts" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.marts.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${local.sa_email.powerbi}"
}

resource "google_project_iam_member" "powerbi_job_user" {
  count = var.manage_identities ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${local.sa_email.powerbi}"
}

# ---------------------------------------------------------------------------
# Logging and metrics for both pipelines. Without logWriter the structured
# logs never arrive, and every log-based alert is silently dead.
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "pipeline_log_writer" {
  for_each = var.manage_identities ? local.pipeline_sa_emails : {}

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "pipeline_metric_writer" {
  for_each = var.manage_identities ? local.pipeline_sa_emails : {}

  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${each.value}"
}
