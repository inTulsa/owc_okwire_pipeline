# ---------------------------------------------------------------------------
# Workload Identity Federation for GitHub Actions. No JSON keys.
# ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "okw-github-${var.env}"
  project                   = var.project_id
  display_name              = "OWC GitHub Actions (${var.env})"
  description               = "Keyless deploys from ${var.github_repository}."
}

locals {
  # Conditions are ANDed. The repository check is mandatory; the ref check is
  # added when allowed_refs is non-empty.
  repository_condition = "assertion.repository == \"${var.github_repository}\""
  ref_condition = length(var.allowed_refs) == 0 ? null : format(
    "(%s)",
    join(" || ", [for r in var.allowed_refs : "assertion.ref == \"${r}\""])
  )
  attribute_condition = join(" && ", compact([local.repository_condition, local.ref_condition]))
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  project                            = var.project_id
  display_name                       = "GitHub OIDC"

  # THE critical line. Without it, any repository on GitHub can mint tokens
  # for this project. See the variable's documentation.
  attribute_condition = local.attribute_condition

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.workflow"         = "assertion.workflow"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ---------------------------------------------------------------------------
# The deployer.
# ---------------------------------------------------------------------------
resource "google_service_account" "deployer" {
  account_id   = "okw-deployer-${var.env}"
  project      = var.project_id
  display_name = "OWC GitHub Actions deployer (${var.env})"
  description  = "Assumed via WIF from ${var.github_repository}. No keys."
}

# Only principals matching the provider's attribute_condition AND this
# repository attribute can impersonate the deployer.
resource "google_service_account_iam_member" "github_may_impersonate" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_artifact_registry_repository_iam_member" "deployer_writer" {
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deployer.email}"
}

# run.developer so the deployer can update a job definition. Note this is
# broader than the scheduler's run.invoker on purpose — deploying and
# triggering are different jobs with different identities.
resource "google_project_iam_member" "deployer_run" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# Setting a service account on a Cloud Run job requires actAs on that SA.
# Scoped to the specific runtime SAs rather than granted project-wide.
resource "google_service_account_iam_member" "deployer_act_as" {
  for_each = toset(var.impersonatable_service_accounts)

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_storage_bucket_iam_member" "deployer_state" {
  bucket = var.state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.deployer.email}"
}

# Terraform reads and writes the whole platform config, so the deployer needs
# to administer the resources this repo manages. Narrowed from owner: no
# billing, no org policy, no project deletion.
resource "google_project_iam_member" "deployer_platform" {
  for_each = toset([
    "roles/storage.admin",
    "roles/bigquery.admin",
    "roles/cloudscheduler.admin",
    "roles/secretmanager.admin",
    "roles/monitoring.editor",
    "roles/logging.configWriter",
    "roles/iam.serviceAccountAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/artifactregistry.admin",
    "roles/bigquery.dataOwner",
    "roles/cloudbuild.builds.editor",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}
