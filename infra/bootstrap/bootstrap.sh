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
# BILLED. State objects are small so the cost is trivial, but set it for
# consistency with the buckets Terraform manages. The flag is
# --clear-soft-delete (not --clear-soft-delete-policy), and errors are shown
# rather than swallowed — a silently-skipped update is how the default
# survives unnoticed.
gcloud storage buckets update "gs://$STATE_BUCKET" \
  --clear-soft-delete --project "$PROJECT_ID"

# ---------------------------------------------------------------------------
# 3. Preflight the credentials Terraform will actually use.
#
# gcloud and Terraform authenticate DIFFERENTLY: the CLI uses the account from
# `gcloud auth login`, Terraform uses Application Default Credentials. A stale
# ADC quota project makes every GCS call return
#   404 "The requested project was not found"
# which Terraform's GCS backend reports as the very misleading
#   "Failed to get existing workspaces: ... storage: bucket doesn't exist"
# even though the bucket is fine. Catching it here costs a second and saves
# that debugging session.
# ---------------------------------------------------------------------------
say "Checking the credentials Terraform will use (ADC)"

if ! ADC_TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null); then
  cat >&2 <<'ADCERR'
No usable Application Default Credentials.

gcloud's own login is separate from what Terraform uses. Run:
    gcloud auth application-default login
ADCERR
  exit 1
fi

ADC_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
ADC_QUOTA=""
if [[ -f "$ADC_FILE" ]]; then
  ADC_QUOTA=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('quota_project_id',''))" "$ADC_FILE" 2>/dev/null || true)
fi

# Mirror the client library: it sends the ADC quota project as
# x-goog-user-project, so the check has to send it too or it tests nothing.
declare -a QUOTA_HEADER=()
if [[ -n "$ADC_QUOTA" ]]; then
  echo "ADC quota project: $ADC_QUOTA"
  QUOTA_HEADER=(-H "x-goog-user-project: $ADC_QUOTA")
fi

# This is the exact call the GCS backend makes to enumerate workspaces.
HTTP_CODE=$(curl -s -o /tmp/okw_adc_check.json -w '%{http_code}' \
  -H "Authorization: Bearer $ADC_TOKEN" "${QUOTA_HEADER[@]}" \
  "https://storage.googleapis.com/storage/v1/b/${STATE_BUCKET}/o?prefix=env&maxResults=1" || echo 000)

if [[ "$HTTP_CODE" != "200" ]]; then
  MSG=$(python3 -c "
import json,sys
try:
    e = json.load(open('/tmp/okw_adc_check.json')).get('error', {})
    print(f\"{e.get('code','?')} {e.get('message','')}\")
except Exception:
    print('(no error body)')
" 2>/dev/null)
  {
    echo ""
    echo "ADC cannot read gs://$STATE_BUCKET  (HTTP $HTTP_CODE: $MSG)"
    echo ""
    # NOTE: `gcloud projects describe` exits 0 for a project in
    # DELETE_REQUESTED state, so checking the exit code is not enough — the
    # lifecycle state is what decides whether it can be billed.
    QUOTA_STATE=""
    if [[ -n "$ADC_QUOTA" ]]; then
      QUOTA_STATE=$(gcloud projects describe "$ADC_QUOTA" \
        --format='value(lifecycleState)' 2>/dev/null || echo "NOT_FOUND")
    fi
    if [[ -n "$ADC_QUOTA" && "$QUOTA_STATE" != "ACTIVE" ]]; then
      echo "Cause: the ADC quota project '$ADC_QUOTA' is not usable (state: ${QUOTA_STATE:-NOT_FOUND})."
      echo "       Every GCS call is billed to it, so they all 404 — and Terraform"
      echo "       reports that as \"bucket doesn't exist\", which it is not."
      echo ""
      echo "Fix:   gcloud auth application-default set-quota-project $PROJECT_ID"
    else
      echo "Fix:   gcloud auth application-default set-quota-project $PROJECT_ID"
      echo "   or: gcloud auth application-default login"
    fi
    echo ""
  } >&2
  exit 1
fi
echo "ADC can read gs://$STATE_BUCKET — Terraform will be able to init"

say "Done. Next — these are steps 2-6 of docs/03-gcp-setup.md:"
cat <<NEXT
  2. Fill in infra/terraform/envs/<env>/terraform.tfvars
       project_id, github_repository, alert_emails, snowflake_user

  3. Create Artifact Registry + the secret container. Building before this
     fails with: name unknown: Repository "okw-images" not found
       make tf-bootstrap ENV=<env>

  4. Store the Snowflake password. Do this BEFORE step 6 -- the lightcast job
     reads versions/latest at creation time, and "latest" cannot resolve to
     nothing. The value never enters Terraform state.
       printf '%s' 'THE_PASSWORD' | \\
         gcloud secrets versions add okw-snowflake-password-<env> \\
           --data-file=- --project $PROJECT_ID

  5. Build an image. Terraform requires a digest, not a tag; this prints it:
       make build ENV=<env>

  6. Apply the rest — this is what creates the Cloud Run jobs and schedulers:
       IMAGE=\$(make -s image-digest ENV=<env>)
       make tf-apply ENV=<env> TF_ARGS="-var=image_digest=\$IMAGE"

  Full walkthrough: docs/03-gcp-setup.md
NEXT
