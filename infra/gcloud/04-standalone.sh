#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Emit a single, self-contained setup script for a project admin to run.
#
# The admin may reasonably decline both "let me have those roles" and "clone
# our repo into your Cloud Shell". This leaves one more option: a flat file
# with every command written out, no dependencies but gcloud, that they can
# read start to finish before running.
#
# Generated from names.sh, so the commands cannot drift from what the rest
# of this repo expects.
#
#   ./infra/gcloud/04-standalone.sh owc-dpar-d \
#       --principal user:someone@agency.ok.gov > owc-setup.sh
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT=""; PREFIX=""; PRINCIPAL=""; LOCATION="US"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --principal) PRINCIPAL="${2:?}"; shift 2 ;;
    --location)  LOCATION="${2:?}"; shift 2 ;;
    *)           PROJECT="$1"; shift ;;
  esac
done
[[ -n "$PROJECT" ]] || { echo "usage: $0 <project-id> [--prefix P] --principal MEMBER" >&2; exit 64; }
PREFIX="${PREFIX:-$PROJECT}"
[[ -n "$PRINCIPAL" ]] || PRINCIPAL="user:$(gcloud config get-value account 2>/dev/null)"

# shellcheck source=names.sh
source "$(dirname "${BASH_SOURCE[0]}")/names.sh"

emit() { printf '%s\n' "$*"; }

emit "#!/usr/bin/env bash"
emit "# ============================================================================"
emit "# OWC data platform — one-time setup for $PROJECT"
emit "#"
emit "# FOR THE PROJECT ADMIN. The OWC deploy account cannot run this — it"
emit "# fails at step 4 with a 403, which is the point: that account is not"
emit "# allowed to create identities or write the project IAM policy."
emit "#"
emit "# Run once, by someone holding on $PROJECT:"
emit "#     roles/iam.serviceAccountAdmin"
emit "#     roles/resourcemanager.projectIamAdmin"
emit "#     roles/serviceusage.serviceUsageAdmin"
emit "#"
emit "# Creates 6 service accounts and their IAM. After this, the deploy runs"
emit "# with resource-admin roles only and never touches the project IAM policy"
emit "# again — which is the point of doing it here rather than in Terraform."
emit "#"
emit "# Idempotent: safe to re-run, and re-running repairs a partial run."
emit "# Nothing outside $PROJECT is touched. No owner, editor or custom roles."
emit "#"
emit "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) from infra/gcloud/names.sh"
emit "# ============================================================================"
emit "set -euo pipefail"
emit ""
emit "PROJECT=$PROJECT"
emit "DEPLOYER=$PRINCIPAL"
emit ""
emit '# Refuse to run against the wrong project.'
emit 'ACTIVE=$(gcloud config get-value project 2>/dev/null || true)'
emit 'if [[ "$ACTIVE" != "$PROJECT" ]]; then'
emit '  echo "gcloud is pointed at ${ACTIVE:-<unset>}, not $PROJECT." >&2'
emit '  echo "Run: gcloud config set project $PROJECT" >&2'
emit '  exit 1'
emit 'fi'
emit ''
emit 'step() { printf "\n==> %s\n" "$*"; }'
emit ''

emit "step \"1/6  Enabling APIs (${#REQUIRED_APIS[@]})\""
emit "gcloud services enable \\"
for a in "${REQUIRED_APIS[@]}"; do emit "  $a \\"; done
emit "  --project \"\$PROJECT\""
emit ""

emit 'step "2/6  Provisioning the BigQuery Data Transfer service agent"'
emit '# Enabling an API does not create its service agent; the agent appears'
emit '# the first time the service is used. Forcing it now means the grant in'
emit '# step 5 has something to attach to.'
emit 'gcloud beta services identity create \'
emit '  --service=bigquerydatatransfer.googleapis.com --project "$PROJECT"'
emit 'PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)")'
emit 'DTS_AGENT="service-${PROJECT_NUMBER}@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"'
emit ""

emit 'step "3/6  Creating the two GCS buckets"'
emit '# Terraform cannot create the bucket that holds its own state, and the'
emit '# source bucket is a mirror of the repo for anyone without GitHub access.'
for b in "$BUCKET_STATE" "$BUCKET_SOURCE"; do
  emit "if ! gcloud storage buckets describe gs://$b --project \"\$PROJECT\" >/dev/null 2>&1; then"
  emit "  gcloud storage buckets create gs://$b --project \"\$PROJECT\" \\"
  emit "    --location $LOCATION --uniform-bucket-level-access --public-access-prevention"
  emit "else"
  emit "  echo \"    gs://$b already exists\""
  emit "fi"
  emit "gcloud storage buckets update gs://$b --versioning --project \"\$PROJECT\""
done
emit "gcloud storage buckets update gs://$BUCKET_STATE --clear-soft-delete --project \"\$PROJECT\""
emit ""

emit "step \"4/6  Creating ${#ALL_SAS[@]} service accounts\""
emit '# One per job, so each holds only what it needs: the web scraper cannot'
emit '# read the Snowflake password, and the Snowflake job cannot write the'
emit "# scraper's cache."
while read -r id display desc; do :; done <<< ""
add_sa() {
  local id="$1" display="$2" desc="$3"
  emit "if ! gcloud iam service-accounts describe sa-$PREFIX-$id-1@$PROJECT.iam.gserviceaccount.com --project \"\$PROJECT\" >/dev/null 2>&1; then"
  emit "  gcloud iam service-accounts create sa-$PREFIX-$id-1 --project \"\$PROJECT\" \\"
  emit "    --display-name '$display' --description '$desc'"
  emit "else"
  emit "  echo \"    sa-$PREFIX-$id-1 already exists\""
  emit "fi"
}
add_sa lightcast  "OWC lightcast pipeline"      "Runs the lightcast Cloud Run job. Holds the Snowflake secret."
add_sa enrollment "OWC enrollment pipeline"     "Runs the enrollment Cloud Run job. No secret access: the source is a public webpage."
add_sa scheduler  "OWC Cloud Scheduler invoker" "Invokes the Cloud Run jobs. run.invoker on the specific jobs only."
add_sa build      "OWC Cloud Build"             "Runs container builds. Reads build source, writes the image and logs. Nothing else."
add_sa powerbi    "OWC PowerBI reader"          "Read-only on owc_marts."
add_sa freshness  "OWC freshness check"         "Runs the owc_ops.pipeline_runs freshness scheduled query. Read-only."
emit ""

emit "step \"5/6  Project-level roles for those accounts (${#RUNTIME_PROJECT_GRANTS[@]})\""
emit '# Narrow on purpose: writing logs, writing metrics, and running a'
emit '# BigQuery job. Nothing broader.'
for g in "${RUNTIME_PROJECT_GRANTS[@]}"; do
  key="${g%%|*}"; role="${g##*|}"
  emit "gcloud projects add-iam-policy-binding \"\$PROJECT\" \\"
  emit "  --member serviceAccount:$(sa_email "$key") \\"
  emit "  --role $role --condition=None --quiet >/dev/null"
done
emit ""
emit '# The Data Transfer agent runs a scheduled query as the freshness'
emit '# account, so it needs to mint tokens for that one account.'
emit "gcloud iam service-accounts add-iam-policy-binding $SA_FRESHNESS \\"
emit '  --project "$PROJECT" --member "serviceAccount:$DTS_AGENT" \'
emit '  --role roles/iam.serviceAccountTokenCreator --quiet >/dev/null'
emit ""

emit "step \"6/6  Letting the deploy account attach those identities (${#ATTACHED_SAS[@]})\""
emit '# Setting a service account on a Cloud Run job, a Scheduler job, a build'
emit '# or a scheduled query requires actAs ON THAT ACCOUNT. Granted per'
emit '# account, never project-wide.'
for t in "${ATTACHED_SAS[@]}"; do
  emit "gcloud iam service-accounts add-iam-policy-binding $t \\"
  emit "  --project \"\$PROJECT\" --member \"\$DEPLOYER\" \\"
  emit "  --role roles/iam.serviceAccountUser --quiet >/dev/null"
done
emit ""
emit '# The ten resource-admin roles the deploy needs. Harmless to re-run if'
emit '# the account already has them.'
for r in "${TF_PRINCIPAL_ROLES[@]}"; do
  emit "gcloud projects add-iam-policy-binding \"\$PROJECT\" \\"
  emit "  --member \"\$DEPLOYER\" --role $r --condition=None --quiet >/dev/null"
done
emit ""
emit 'printf "\n==> Done. Nothing else needs these permissions again.\n"'
emit 'printf "    Tell the OWC team; they verify from their side and can show you\n"'
emit 'printf "    the result.\n\n"'
