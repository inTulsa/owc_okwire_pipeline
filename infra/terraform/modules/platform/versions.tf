terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
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
