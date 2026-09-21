terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.12, < 8.0"
    }
    # Used by the platform module for google_project_service_identity only,
    # which has no GA equivalent.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.12, < 8.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12, < 1.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
