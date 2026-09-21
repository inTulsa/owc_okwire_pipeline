resource "google_artifact_registry_repository" "images" {
  repository_id = "okw-images"
  project       = var.project_id
  location      = var.region
  format        = "DOCKER"
  description   = "One image for both pipelines, referenced by digest in Terraform."
  labels        = var.labels

  # Keep the last 10 builds; untagged layers from superseded builds go after
  # 30 days. Long enough that a rollback target is always still there.
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s" # 30 days
    }
  }

  depends_on = [google_project_service.enabled]
}

# Both jobs pull the same image.
resource "google_artifact_registry_repository_iam_member" "pipeline_readers" {
  for_each = local.pipeline_sa_emails

  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${each.value}"
}
