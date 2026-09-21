terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.12, < 8.0"
    }
    # Needed for exactly one resource: google_project_service_identity, which
    # has no GA equivalent. Enabling an API does NOT create its service agent
    # — the agent appears the first time the service is used — so granting a
    # role to it right after enabling the API fails with
    # "Service account service-<num>@gcp-sa-<svc>.iam.gserviceaccount.com
    # does not exist". This resource provisions it explicitly.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.12, < 8.0"
    }
    # Used only for the metric-propagation waits in alerts. A newly created
    # log-based metric is not immediately visible to the Monitoring API, so
    # creating an alert policy that references it fails with a 404 even though
    # depends_on ordered them correctly.
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12, < 1.0"
    }
  }
}
