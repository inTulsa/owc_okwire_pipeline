terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
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

