# ---------------------------------------------------------------------------
# The Snowflake password.
#
# Password auth is correct and is NOT deprecated here: Snowflake's password
# phase-out explicitly exempts reader accounts. The only change from the
# original pipeline is that the password lives here instead of in a .env file.
# See docs/01-architecture.md ADR-004 and open item 3.
#
# The secret VALUE is set out of band (gcloud, or the console) and is not in
# Terraform state:
#   printf '%s' "$PASSWORD" | gcloud secrets versions add okw-snowflake-password-dev --data-file=-
# ---------------------------------------------------------------------------
resource "google_secret_manager_secret" "snowflake_password" {
  secret_id = "okw-snowflake-password-${var.env}"
  project   = var.project_id
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# Only the lightcast SA. The enrollment SA is deliberately absent — its source
# is a public webpage and it has no reason to be able to read this.
# Verification for phase 2: confirm the enrollment SA CANNOT read this secret.
resource "google_secret_manager_secret_iam_member" "lightcast_accessor" {
  secret_id = google_secret_manager_secret.snowflake_password.id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.lightcast.email}"
}
