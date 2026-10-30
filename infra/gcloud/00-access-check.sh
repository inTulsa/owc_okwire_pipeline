#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Read-only. Answers "where do I stand on this project, and what do I have to
# ask someone else for?"
#
# Run this FIRST on any project you did not create. It needs no special
# permission: it asks the IAM API what the caller can do
# (projects.testIamPermissions), which any principal may call about itself,
# rather than reading the project policy — which on an OMES project you will
# not be allowed to do.
#
#   ./infra/gcloud/00-access-check.sh owc-dpar-d
# ---------------------------------------------------------------------------
set -uo pipefail

PROJECT="${1:-}"
PREFIX="${2:-$PROJECT}"
[[ -n "$PROJECT" ]] || { echo "usage: $0 <project-id> [name-prefix]" >&2; exit 64; }

# shellcheck source=names.sh
source "$(dirname "${BASH_SOURCE[0]}")/names.sh"

yes() { printf '  \033[32mYES\033[0m  %-38s %s\n' "$1" "$2"; }
no()  { printf '  \033[31mNO \033[0m  %-38s %s\n' "$1" "$2"; }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# permission|the role that carries it
DEPLOY_PERMS=(
  "storage.buckets.create|roles/storage.admin"
  "bigquery.datasets.create|roles/bigquery.admin"
  "run.jobs.create|roles/run.admin"
  # Writing a Cloud Run job's IAM policy — modules/pipeline/job.tf grants the
  # scheduler run.developer on each job. roles/run.developer cannot do this;
  # roles/run.admin can, which is why the deploy identity holds the latter.
  "run.jobs.setIamPolicy|roles/run.admin"
  "cloudscheduler.jobs.create|roles/cloudscheduler.admin"
  "secretmanager.secrets.create|roles/secretmanager.admin"
  "artifactregistry.repositories.create|roles/artifactregistry.admin"
  "monitoring.alertPolicies.create|roles/monitoring.editor"
  "logging.logMetrics.create|roles/logging.configWriter"
  "cloudbuild.builds.create|roles/cloudbuild.builds.editor"
  "serviceusage.services.use|roles/serviceusage.serviceUsageConsumer"
)
ADMIN_PERMS=(
  "iam.serviceAccounts.create|roles/iam.serviceAccountAdmin"
  "resourcemanager.projects.setIamPolicy|roles/resourcemanager.projectIamAdmin"
  # NOTE: roles/monitoring.editor also carries this one, so a YES here does
  # NOT prove the caller holds serviceUsageAdmin. See OPEN-ITEMS item 10.
  "serviceusage.services.enable|serviceUsageAdmin — or monitoring.editor"
)
all=()
for e in "${DEPLOY_PERMS[@]}" "${ADMIN_PERMS[@]}"; do all+=("${e%%|*}"); done

printf '\n\033[1mAccess check — %s\033[0m\n' "$PROJECT"
printf '  account: %s\n' "$(gcloud config get-value account 2>/dev/null)"
# This answers for whoever the call is MADE AS, which under the deploy-identity
# model is the impersonated service account, not the person at the keyboard.
# Saying which makes a screenful of NO self-explanatory instead of alarming.
if [[ -n "${CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT:-}" ]]; then
  printf '  acting as: %s\n' "$CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT"
  printf '  \033[2m%s\033[0m\n' "(impersonated — this is what the deploy will actually be)"
else
  printf '  acting as: itself — NOT impersonating the deploy account\n'
  printf '  \033[2m%s\033[0m\n' "Deploy permissions below will read NO, which is correct for a"
  printf '  \033[2m%s\033[0m\n' "person. Run: eval \"\$(make -s env-exports ENV=<env>)\""
fi

# projects.testIamPermissions, called directly.
#
# There is no `gcloud projects test-iam-permissions` — the CLI does not
# expose this verb, only get/set-iam-policy, which need permissions you will
# not have on a project you do not administer. The REST method is the point
# of the whole check: ANY principal may ask it what IT can do, so it works
# exactly where reading the policy does not.
TOKEN=$(gcloud auth print-access-token 2>/dev/null) || {
  echo ""
  echo "No gcloud credentials. Run: gcloud auth login"
  exit 1
}

BODY=$(python3 -c '
import json, sys
print(json.dumps({"permissions": sys.argv[1:]}))
' "${all[@]}")

PERMS_UNKNOWN=0
RESP=$(mktemp); trap 'rm -f "$RESP"' EXIT
CODE=$(curl -s -o "$RESP" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT}:testIamPermissions" \
  || echo 000)

if [[ "$CODE" != "200" ]]; then
  msg=$(python3 -c "
import json,sys
try:
    e = json.load(open(sys.argv[1])).get('error', {})
    print(f\"{e.get('status','')} {e.get('message','')}\".strip())
except Exception:
    print('(no error body)')
" "$RESP" 2>/dev/null)
  echo ""
  echo "Could not query your permissions on $PROJECT  (HTTP $CODE)"
  echo "  $msg"
  echo ""
  case "$CODE" in
    403) echo "  Your account has no access to this project at all, or the"
         echo "  Cloud Resource Manager API is not enabled on it." ;;
    404) echo "  No such project, or it is not visible to this account." ;;
    *)   echo "  Unexpected. Check the project id and that you are logged in." ;;
  esac
  echo ""
  echo "  account: $(gcloud config get-value account 2>/dev/null)"
  echo "  project: $PROJECT"
  echo ""
  echo "  Continuing with the checks that need no special access."
  PERMS_UNKNOWN=1
fi

GRANTED=$(python3 -c "
import json,sys
print('\n'.join(json.load(open(sys.argv[1])).get('permissions', [])))
" "$RESP")
has() { grep -qx -- "$1" <<<"$GRANTED"; }

deploy_missing=0
admin_have=0
if (( PERMS_UNKNOWN )); then
  head2 "Your permissions"
  printf '  could not be determined — see the error above\n'
else
head2 "Can you run the deploy? (steps 7-8)"
for e in "${DEPLOY_PERMS[@]}"; do
  p="${e%%|*}"; r="${e##*|}"
  if has "$p"; then yes "$p" "$r"; else no "$p" "$r"; deploy_missing=$((deploy_missing+1)); fi
done

head2 "Can you run the one privileged step? (step 5b)"
for e in "${ADMIN_PERMS[@]}"; do
  p="${e%%|*}"; r="${e##*|}"
  if has "$p"; then yes "$p" "$r"; admin_have=$((admin_have+1)); else no "$p" "$r"; fi
done

fi

# An organization may restrict where resources can live. Finding that out
# from a failed apply is expensive: the secret dies on `global`, and GCS and
# BigQuery would die on a multi-region `US` if the policy is region-only.
# Reading it up front costs one call and is usually permitted.
head2 "Location policy"
if pol=$(gcloud resource-manager org-policies describe \
      constraints/gcp.resourceLocations --project "$PROJECT" --effective \
      --format='value(listPolicy.allowedValues)' 2>/dev/null); then
  if [[ -z "$pol" || "$pol" == *"allValues"* ]]; then
    printf '  \033[32mok\033[0m   %s\n' "no location restriction in effect"
  else
    printf '  \033[33mnote\033[0m     allowed locations: %s\n' "$(tr ',' ' ' <<<"$pol")"
    printf '  \033[2m%s\033[0m\n' "Secret Manager cannot use 'global' here — the config pins the"
    printf '  \033[2m%s\033[0m\n' "secret to \$REGION, which is correct for this. If GCS or BigQuery"
    printf '  \033[2m%s\033[0m\n' "fail on location, set location = a permitted region in tfvars;"
    printf '  \033[2m%s\033[0m\n' "they must match each other or load jobs fail."
  fi
else
  printf '  \033[2mskip\033[0m     cannot read the org policy (usually fine; it may still apply)\n'
fi

head2 "What already exists"
# Reading a service account needs iam.serviceAccounts.get, which the deploy
# identity has only via serviceAccountUser on the five it attaches. powerbi
# is deliberately not one of them, so an impersonated run cannot see it and
# must not report that as absent — the verdict below keys off this.
sa_found=0; sa_missing=0; sa_unknown=0
for email in "${ALL_SAS[@]}"; do
  if out=$(gcloud iam service-accounts describe "$email" --project "$PROJECT" 2>&1); then
    sa_found=$((sa_found+1))
  else
    case "$out" in
      *NOT_FOUND*|*"not found"*|*"Unknown service account"*) sa_missing=$((sa_missing+1)) ;;
      *) sa_unknown=$((sa_unknown+1)) ;;
    esac
  fi
done
printf '  service accounts : %d of %d visible' "$sa_found" "${#ALL_SAS[@]}"
(( sa_missing )) && printf ', \033[31m%d MISSING\033[0m' "$sa_missing"
(( sa_unknown )) && printf ', %d not readable as this identity' "$sa_unknown"
printf '\n'
if (( sa_unknown )); then
  printf '  \033[2m%s\033[0m\n' "Not readable is expected while impersonating the deploy account: it"
  printf '  \033[2m%s\033[0m\n' "holds actAs on the five it attaches, and powerbi is deliberately not"
  printf '  \033[2m%s\033[0m\n' "one of them. Not evidence of absence."
fi

api_on=0
if enabled=$(gcloud services list --enabled --project "$PROJECT" --format='value(config.name)' 2>/dev/null); then
  for a in "${REQUIRED_APIS[@]}"; do grep -qx "$a" <<<"$enabled" && api_on=$((api_on+1)); done
  printf '  APIs enabled     : %d of %d\n' "$api_on" "${#REQUIRED_APIS[@]}"
else
  printf '  APIs enabled     : cannot list (no serviceusage read access)\n'
fi

for b in "$BUCKET_STATE" "$BUCKET_SOURCE"; do
  if gcloud storage buckets describe "gs://$b" --project "$PROJECT" >/dev/null 2>&1; then
    printf '  gs://%-28s exists\n' "$b"
  else
    printf '  gs://%-28s missing\n' "$b"
  fi
done

# ---------------------------------------------------------------------------
head2 "Verdict"
if (( PERMS_UNKNOWN )); then
  echo "  Cannot tell what you are allowed to do, so start by asking."
  echo "  Send your project admin the request:"
  echo ""
  echo "    make omes-request ENV=<env> > owc-setup-request.txt"
  echo ""
  echo "  If Cloud Resource Manager is simply not enabled on the project yet,"
  echo "  the request's first command turns it on along with the other 15."
elif (( admin_have == 3 )); then
  echo "  You can run everything yourself, including step 4:"
  echo ""
  echo "    make gcloud-admin ENV=<env>"
elif (( sa_missing == 0 && deploy_missing == 0 )); then
  echo "  Step 4 has been done and you have what the deploy needs. Continue:"
  echo ""
  echo "    make up ENV=<env>"
else
  if (( deploy_missing == 0 )); then
    echo "  You already have everything the DEPLOY needs. What is missing is only"
    echo "  the one-time setup, which needs two roles you do not have."
  else
    echo "  You are missing $deploy_missing role(s) the deploy needs, and the two the"
    echo "  one-time setup needs."
  fi
  echo ""
  echo "  That is step 5a. It is the only thing anyone else has to do:"
  echo ""
  echo "    make omes-request ENV=<env>"
fi
echo ""
