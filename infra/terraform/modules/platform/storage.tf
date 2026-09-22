# ---------------------------------------------------------------------------
# Raw landing zone: Parquet, archived Excel originals, page snapshots.
# Prefixed per pipeline (lightcast/, enrollment/) so each pipeline's service
# account can be scoped to its own prefix and cannot touch the other's.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "raw" {
  name     = local.name.raw_bucket
  project  = var.project_id
  location = var.location
  labels   = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.raw_bucket_force_destroy

  versioning {
    enabled = true
  }

  # Defaults to 7 days on new buckets, and retained deleted bytes are BILLED.
  # Without this, every lifecycle deletion below keeps costing for another
  # week — the lifecycle rules would be buying nothing.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    condition { age = 30 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  lifecycle_rule {
    condition { age = 365 }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }
  # Noncurrent versions are a safety net, not an archive.
  lifecycle_rule {
    condition {
      num_newer_versions = 3
      with_state         = "ARCHIVED"
    }
    action { type = "Delete" }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.enabled]
}

# ---------------------------------------------------------------------------
# The enrollment scraper's cache, mounted into the job with FUSE.
#
# A SEPARATE bucket on purpose: the raw bucket's lifecycle rules must never be
# able to expire a file the script expects to find with os.path.exists(). If
# they did, the scraper would silently re-download Oklahoma's entire back
# catalogue. No lifecycle deletion here, ever.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "enrollment_state" {
  name     = local.name.enrollment_state_bucket
  project  = var.project_id
  location = var.location
  labels   = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  # Deliberately no lifecycle_rule with a Delete action. Age is not a reason
  # to remove a cached workbook; the cache is the pipeline's memory.

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.enabled]
}
