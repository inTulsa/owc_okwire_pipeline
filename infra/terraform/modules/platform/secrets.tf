# ---------------------------------------------------------------------------
# The Snowflake password.
#
# Password auth is correct and is NOT deprecated here: Snowflake's password
# phase-out explicitly exempts reader accounts. The only change from the
# original pipeline is that the password lives here instead of in a .env file.
# See docs/architecture.md ADR-004 and open item 3.
#
# The secret VALUE is set out of band (gcloud, or the console) and is not in
# Terraform state:
#   printf '%s' "$PASSWORD" | gcloud secrets versions add "$(terraform output -raw snowflake_secret_id)" --data-file=-
# ---------------------------------------------------------------------------
locals {
  # Defaults to the one region that actually reads this secret.
  secret_replica_locations = length(var.secret_replica_locations) > 0 ? var.secret_replica_locations : [var.region]
}

resource "google_secret_manager_secret" "snowflake_password" {
  secret_id = local.name.secret_snowflake
  project   = var.project_id
  labels    = var.labels

  # user_managed, not auto.
  #
  # `auto {}` creates the secret in `global`, which an organization running
  # constraints/gcp.resourceLocations will refuse:
  #
  #   Error 400: Constraint constraints/gcp.resourceLocations violated for
  #   [orgpolicy:projects/...] attempting to create a secret in [global]
  #
  # Naming the replica regions explicitly satisfies that policy, and is
  # correct even where the policy is absent: this secret is read by a Cloud
  # Run job in var.region, so replicating it anywhere else buys nothing.
  replication {
    user_managed {
      dynamic "replicas" {
        for_each = toset(local.secret_replica_locations)
        content {
          location = replicas.value
        }
      }
    }
  }

  # Replication is fixed at creation: changing these forces replacement, and
  # a replaced secret loses its versions. The password would have to be
  # stored again, and the lightcast job cannot start without it.
  lifecycle {
    ignore_changes = [replication]
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
