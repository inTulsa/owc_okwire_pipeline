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
#   printf '%s' "$PASSWORD" | gcloud secrets versions add "$(terraform output -raw snowflake_secret_id)" --data-file=-
# ---------------------------------------------------------------------------
resource "google_secret_manager_secret" "snowflake_password" {
  secret_id = local.name.secret_snowflake
  project   = var.project_id
  labels    = var.labels

  replication {
    auto {}
  }

}

# Only the lightcast SA. The enrollment SA is deliberately absent — its source
# is a public webpage and it has no reason to be able to read this.
# Verification for phase 2: confirm the enrollment SA CANNOT read this secret.
resource "google_secret_manager_secret_iam_member" "lightcast_accessor" {
  secret_id = google_secret_manager_secret.snowflake_password.id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.sa_email.lightcast}"
}
