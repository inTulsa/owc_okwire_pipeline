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

PROJECT=""; PREFIX=""; PRINCIPAL=""; LOCATION="US"; REGION="us-central1"
# Which half to emit.
#
#   operator  APIs, the Data Transfer agent, the two buckets. Everything the
#             deploy account can already do, so it does not belong in a
#             request to somebody else.
#   admin     the six identities and their IAM. The only part that needs
#             serviceAccountAdmin and projectIamAdmin.
#   all       both, for a project where one person holds everything.
#
# Splitting matters because the admin's file should contain nothing they
# have to wonder about. A bucket creation sitting in the middle of an IAM
# request is a question, and questions cost days.
PART="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --principal) PRINCIPAL="${2:?}"; shift 2 ;;
    --location)  LOCATION="${2:?}"; shift 2 ;;
    --region)    REGION="${2:?}"; shift 2 ;;
    --part)      PART="${2:?}"; shift 2 ;;
    *)           PROJECT="$1"; shift ;;
  esac
done
case "$PART" in operator|admin|all) ;; *) echo "--part must be operator, admin or all" >&2; exit 64 ;; esac
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
if [[ "$PART" == "operator" ]]; then
  emit "# Run by the OWC deploy account. Needs no elevated rights: enabling APIs"
  emit "# and creating buckets are things that account already does."
else
  emit "# FOR THE PROJECT ADMIN. The OWC deploy account cannot run this — it"
  emit "# fails on the first command with a 403, which is the point: that"
  emit "# account is not allowed to create identities or write project IAM."
  emit "#"
  emit "# Run once, by someone holding on $PROJECT:"
  emit "#     roles/iam.serviceAccountAdmin"
  emit "#     roles/resourcemanager.projectIamAdmin"
fi
emit "#"
if [[ "$PART" == "operator" ]]; then
  emit "# Prepares the project so the identity setup, and then Terraform, can"
  emit "# run. Nothing here creates an identity or grants a role."
else
  emit "# Creates ${#ALL_SAS[@]} service accounts and their IAM. After this, the deploy"
  emit "# runs with resource-admin roles only and never touches the project IAM"
  emit "# policy again — the point of doing it here rather than in Terraform."
fi
emit "#"
emit "#"
emit "# HOW TO RUN IT"
emit "#   1. Open Cloud Shell on $PROJECT — the terminal icon in the Google"
emit "#      Cloud console toolbar, or https://shell.cloud.google.com"
emit "#   2. Upload this file: the three-dot menu in the Cloud Shell toolbar,"
emit "#      then Upload > File. It lands in your home directory."
emit "#   3. Point gcloud at the project and run it:"
emit "#"
emit "#          gcloud config set project $PROJECT"
emit "#          bash ~/$(basename "${OUT_NAME:-owc-setup.sh}")"
emit "#"
emit "#   Takes about a minute. It prints six numbered steps; if any of them"
emit "#   fails it stops there rather than half-finishing."
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
emit "DEPLOY_SA=$SA_DEPLOY"
emit ""
emit '# ^ CHECK DEPLOYER BEFORE RUNNING.'
emit '#'
emit '# DEPLOYER is the PERSON who will run the deploys. It is NOT the account'
emit '# running this script — it is the person you are doing this for.'
emit '#'
emit '# They receive exactly ONE binding in this project: tokenCreator on'
emit '# DEPLOY_SA. Every resource-admin role goes to DEPLOY_SA instead, and'
emit '# nobody logs in as that. So no human account holds an admin-level role,'
emit '# every deploy action is attributable to whoever minted the token, and'
emit '# revoking access is one binding.'
emit '#'
emit '# If that address is not the deploy operator, stop and ask them for the'
emit '# right one. A wrong value here grants nothing useful to anybody and'
emit '# surfaces as a permission error on their first deploy, not on yours.'
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
emit '# The deploy principal being the account running this script is almost'
emit '# always a mistake: it means whoever generated the request took the'
emit '# default from their own shell. Ask rather than guess.'
emit 'RUNNER="user:$(gcloud config get-value account 2>/dev/null)"'
emit 'if [[ "$DEPLOYER" == "$RUNNER" ]]; then'
emit '  echo "" >&2'
emit '  echo "  DEPLOYER is $DEPLOYER, which is the account running this" >&2'
emit '  echo "  script. That is usually wrong — it should be the person who" >&2'
emit '  echo "  will run the deploys, not the admin setting this up." >&2'
emit '  echo "" >&2'
emit '  echo "  If it is genuinely correct, re-run with:" >&2'
emit '  echo "      DEPLOYER_IS_ME=1 bash \$0" >&2'
emit '  echo "" >&2'
emit '  [[ -n "${DEPLOYER_IS_ME:-}" ]] || exit 1'
emit 'fi'
emit ''

if [[ "$PART" == "all" ]]; then TOTAL=7; elif [[ "$PART" == "admin" ]]; then TOTAL=4; else TOTAL=3; fi
n=0
next_step() { n=$((n+1)); emit "step \"$n/$TOTAL  $1\""; }

if [[ "$PART" != "admin" ]]; then
next_step "Enabling APIs (${#REQUIRED_APIS[@]})"
emit "gcloud services enable \\"
for a in "${REQUIRED_APIS[@]}"; do emit "  $a \\"; done
emit "  --project \"\$PROJECT\""
emit ""

next_step "Provisioning the BigQuery Data Transfer service agent"
emit '# Enabling an API does not create its service agent; the agent appears'
emit '# the first time the service is used. Forcing it now means the grant in'
emit '# step 5 has something to attach to.'
emit 'gcloud beta services identity create \'
emit '  --service=bigquerydatatransfer.googleapis.com --project "$PROJECT"'
emit '# Cloud Scheduler impersonates the scheduler account to mint its OAuth'
emit '# token, so its agent has to exist too.'
emit 'gcloud beta services identity create \'
emit '  --service=cloudscheduler.googleapis.com --project "$PROJECT"'
emit 'PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)")'
emit 'DTS_AGENT="service-${PROJECT_NUMBER}@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"'
emit 'SCHEDULER_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"'
emit ""

next_step "Creating the two GCS buckets"
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

fi   # end operator part

if [[ "$PART" != "operator" ]]; then
next_step "Creating $(( ${#ALL_SAS[@]} + 1 )) service accounts"
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
add_sa scheduler  "OWC Cloud Scheduler invoker" "Invokes the Cloud Run jobs. run.developer on the specific jobs only."
add_sa build      "OWC Cloud Build"             "Runs container builds. Reads build source, writes the image and logs. Nothing else."
add_sa powerbi    "OWC PowerBI reader"          "Read-only on owc_marts."
add_sa freshness  "OWC freshness check"         "Runs the owc_ops.pipeline_runs freshness scheduled query. Read-only."
add_sa deploy     "OWC deploy"                  "Runs Terraform and the gcloud deploy steps. Impersonated by a named person; no human holds its roles."
emit ""

if [[ "$PART" == "admin" ]]; then
  emit '# Resolve the Data Transfer agent address for the grant below. The'
  emit '# agent is created when the API is first used, which the OWC team has'
  emit '# already done.'
  emit 'PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)")'
  emit 'DTS_AGENT="service-${PROJECT_NUMBER}@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"'
  emit ""
fi
next_step "Project-level roles for those accounts (${#RUNTIME_PROJECT_GRANTS[@]})"
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
emit '# Cloud Scheduler impersonates the scheduler account to mint the OAuth'
emit '# token it calls Cloud Run with. roles/cloudscheduler.serviceAgent'
emit '# normally covers this automatically; an organization that strips'
emit '# default grants leaves it absent, and then every scheduled run is a'
emit '# 403 that the run.invoker binding cannot explain.'
emit "gcloud iam service-accounts add-iam-policy-binding $SA_SCHEDULER \\"
emit '  --project "$PROJECT" --member "serviceAccount:$SCHEDULER_AGENT" \'
emit '  --role roles/iam.serviceAccountTokenCreator --quiet >/dev/null'
emit ""

next_step "Letting the DEPLOY ACCOUNT attach those identities (${#ATTACHED_SAS[@]})"
emit '# Setting a service account on a Cloud Run job, a Scheduler job, a build'
emit '# or a scheduled query requires actAs ON THAT ACCOUNT. Granted per'
emit '# account, never project-wide — and to the deploy service account, not'
emit '# to a person.'
for t in "${ATTACHED_SAS[@]}"; do
  emit "gcloud iam service-accounts add-iam-policy-binding $t \\"
  emit "  --project \"\$PROJECT\" --member \"serviceAccount:\$DEPLOY_SA\" \\"
  emit "  --role roles/iam.serviceAccountUser --quiet >/dev/null"
done
emit ""
emit "# The ${#TF_PRINCIPAL_ROLES[@]} resource-admin roles the deploy needs. Harmless to re-run."
emit 'RUN_ROLE=roles/run.admin'
for r in "${TF_PRINCIPAL_ROLES[@]}"; do
  if [[ "$r" == "roles/run.admin" ]]; then
    emit ''
    emit '# roles/run.admin is the one an organization may refuse, and there is a'
    emit '# working answer either way — so this tries it and falls back rather'
    emit '# than stopping. It is needed because Terraform writes a Cloud Run job'
    emit '# IAM policy (run.jobs.setIamPolicy), which roles/run.developer lacks.'
    emit '# Nothing here logs in as this account; it is a service account.'
    emit 'if gcloud projects add-iam-policy-binding "$PROJECT" \'
    emit '     --member "serviceAccount:$DEPLOY_SA" --role roles/run.admin \'
    emit '     --condition=None --quiet >/dev/null 2>&1; then'
    emit '  RUN_ROLE=roles/run.admin'
    emit 'else'
    emit '  printf "    roles/run.admin refused — falling back to roles/run.developer\n"'
    emit '  gcloud projects add-iam-policy-binding "$PROJECT" \'
    emit '    --member "serviceAccount:$DEPLOY_SA" --role roles/run.developer \'
    emit '    --condition=None --quiet >/dev/null'
    emit '  RUN_ROLE=roles/run.developer'
    emit 'fi'
    emit ''
    continue
  fi
  emit "gcloud projects add-iam-policy-binding \"\$PROJECT\" \\"
  emit "  --member \"serviceAccount:\$DEPLOY_SA\" --role $r --condition=None --quiet >/dev/null"
done
emit ""
next_step "Letting the named person use the deploy account (one binding)"
emit '# The only thing a human gets. They impersonate the deploy account;'
emit '# they never hold its roles.'
emit 'gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" \'
emit '  --project "$PROJECT" --member "$DEPLOYER" \'
emit '  --role roles/iam.serviceAccountTokenCreator --quiet >/dev/null'
emit ""
fi   # end admin part

emit ""
if [[ "$PART" == "operator" ]]; then
  emit 'printf "\n==> Done. Next: the project admin runs the identity setup.\n\n"'
else
  emit 'if [[ "$RUN_ROLE" == "roles/run.developer" ]]; then'
  emit '  cat <<RUNDEV'
  emit ''
  emit '==> IMPORTANT — the deploy account has run.developer, not run.admin'
  emit ''
  emit '  Supported, but not finished. run.developer cannot write a Cloud Run'
  emit "  job's IAM policy, so Terraform cannot grant Cloud Scheduler"
  emit '  permission to start the jobs. Two things follow.'
  emit ''
  emit '  1. THE OWC TEAM sets this in their terraform.tfvars before'
  emit '     deploying, or the apply fails on that one resource:'
  emit ''
  emit '       scheduler_job_iam_in_terraform = false'
  emit ''
  emit '  2. YOU run two more commands AFTER their first deploy — the Cloud'
  emit '     Run jobs must exist before anything can be granted on them:'
  emit ''
  emit "       gcloud run jobs add-iam-policy-binding $JOB_LIGHTCAST \\"
  emit "         --region $REGION --project $PROJECT \\"
  emit "         --member serviceAccount:$SA_SCHEDULER \\"
  emit '         --role roles/run.developer'
  emit ''
  emit "       gcloud run jobs add-iam-policy-binding $JOB_ENROLLMENT \\"
  emit "         --region $REGION --project $PROJECT \\"
  emit "         --member serviceAccount:$SA_SCHEDULER \\"
  emit '         --role roles/run.developer'
  emit ''
  emit '  Until step 2 every scheduled run returns 403, silently: the jobs'
  emit '  work by hand and fail on the monthly cron. Tell the OWC team which'
  emit '  way this went — it changes what they have to do.'
  emit ''
  emit 'RUNDEV'
  emit 'fi'
  emit 'printf "\n==> Done. Nothing else needs these permissions again.\n"'
  emit 'printf "    Tell the OWC team; they verify from their side and can show\n"'
  emit 'printf "    you the result.\n\n"'
fi
