# cloudresourcemanager and serviceusage are NOT here: Terraform needs them to
# enable anything at all, so they are enabled by hand once during bootstrap.
# See docs/03-gcp-setup.md.
locals {
  services = [
    "run.googleapis.com",
    "cloudscheduler.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    # Storage Read API — what makes PowerBI reads fast.
    "bigquerystorage.googleapis.com",
    # The freshness dead-man's-switch is a BigQuery scheduled query, which is
    # a Data Transfer Service resource.
    "bigquerydatatransfer.googleapis.com",
    "secretmanager.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  # Enabled by infra/gcloud/01-admin-identities.sh when manage_apis is
  # false, which drops serviceUsageAdmin from the Terraform principal.
  for_each = var.manage_apis ? toset(local.services) : toset([])

  project = var.project_id
  service = each.value

  # Leave APIs on when the config is destroyed. Disabling an API takes other
  # resources with it, and an accidental `terraform destroy` should not be
  # able to cascade that far.
  disable_on_destroy = false
}
