#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time bootstrap. Creates only what Terraform cannot create itself:
#
#   1. The two APIs Terraform needs in order to enable any other API.
#   2. The GCS bucket that holds Terraform's own state.
#
# Everything else is Terraform's job. Run once per project, then never again.
# Idempotent: safe to re-run.
#
#   ./infra/bootstrap/bootstrap.sh owc-data-dev
#   ./infra/bootstrap/bootstrap.sh owc-data-prod
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_ID="${1:-}"
STATE_BUCKET="${STATE_BUCKET:-okw-tfstate}"
LOCATION="${LOCATION:-US}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "usage: $0 <project-id>" >&2
  echo "  env: STATE_BUCKET (default okw-tfstate)  LOCATION (default US)" >&2
  exit 64
fi

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "Project: $PROJECT_ID"
gcloud projects describe "$PROJECT_ID" >/dev/null || {
  echo "Project not found, or you lack access. Create it and link billing first." >&2
  exit 1
}

# -- 1. the two APIs Terraform needs to enable anything else -----------------
# Chicken and egg: google_project_service needs serviceusage to make the call
# and cloudresourcemanager to resolve the project. Terraform cannot enable the
# APIs that let it enable APIs.
say "Enabling the two bootstrap APIs"
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  --project "$PROJECT_ID"

# -- 2. the Terraform state bucket -------------------------------------------
# Terraform cannot create the bucket that holds its own state.
say "Creating state bucket gs://$STATE_BUCKET"
if gcloud storage buckets describe "gs://$STATE_BUCKET" --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "already exists"
else
  gcloud storage buckets create "gs://$STATE_BUCKET" \
    --project "$PROJECT_ID" \
    --location "$LOCATION" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

# Versioning on state is the difference between a bad apply being an
# inconvenience and being an outage.
gcloud storage buckets update "gs://$STATE_BUCKET" --versioning --project "$PROJECT_ID"

# Soft-delete defaults to 7 days on new buckets and retained deleted bytes are
# billed. State objects are small so the cost is trivial, but set it for
# consistency with the buckets Terraform manages.
gcloud storage buckets update "gs://$STATE_BUCKET" \
  --clear-soft-delete-policy --project "$PROJECT_ID" 2>/dev/null || true

say "Done. Next:"
cat <<NEXT
  1. Fill in infra/terraform/envs/<env>/terraform.tfvars
       project_id, github_repository, alert_emails, snowflake_user
  2. Build an image (Terraform requires a digest, not a tag):
       make build ENV=<env>
  3. Store the Snowflake password (the value is never in Terraform state):
       printf '%s' 'THE_PASSWORD' | \\
         gcloud secrets versions add okw-snowflake-password-<env> \\
           --data-file=- --project $PROJECT_ID
       (create the secret with a first apply, then add the version)
  4. Apply:
       make tf-init ENV=<env> && make tf-apply ENV=<env>

  Full walkthrough: docs/03-gcp-setup.md
NEXT
