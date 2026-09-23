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
  "run.jobs.create|roles/run.developer"
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
  "serviceusage.services.enable|roles/serviceusage.serviceUsageAdmin"
)

all=()
for e in "${DEPLOY_PERMS[@]}" "${ADMIN_PERMS[@]}"; do all+=("${e%%|*}"); done

printf '\n\033[1mAccess check — %s\033[0m\n' "$PROJECT"
printf '  account: %s\n' "$(gcloud config get-value account 2>/dev/null)"

if ! GRANTED=$(gcloud projects test-iam-permissions "$PROJECT" \
      --permissions="$(IFS=,; echo "${all[*]}")" \
      --format='value(permissions)' 2>&1); then
  echo ""
  echo "Could not query permissions on $PROJECT:"
  echo "  $(tail -1 <<<"$GRANTED")"
  echo ""
  echo "Either the project id is wrong, or your account has no access to it"
  echo "at all. Both are things to raise before anything else."
  exit 1
fi
GRANTED=$(tr ';' '\n' <<<"$GRANTED")
has() { grep -qx -- "$1" <<<"$GRANTED"; }

deploy_missing=0
head2 "Can you run the deploy? (steps 5-6)"
for e in "${DEPLOY_PERMS[@]}"; do
  p="${e%%|*}"; r="${e##*|}"
  if has "$p"; then yes "$p" "$r"; else no "$p" "$r"; deploy_missing=$((deploy_missing+1)); fi
done

admin_have=0
head2 "Can you run the one privileged step? (step 4)"
for e in "${ADMIN_PERMS[@]}"; do
  p="${e%%|*}"; r="${e##*|}"
  if has "$p"; then yes "$p" "$r"; admin_have=$((admin_have+1)); else no "$p" "$r"; fi
done

head2 "What already exists"
sa_found=0
for email in "${ALL_SAS[@]}"; do
  gcloud iam service-accounts describe "$email" --project "$PROJECT" >/dev/null 2>&1 \
    && sa_found=$((sa_found+1))
done
printf '  service accounts : %d of %d\n' "$sa_found" "${#ALL_SAS[@]}"

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
if (( admin_have == 3 )); then
  echo "  You can run everything yourself, including step 4:"
  echo ""
  echo "    make gcloud-admin ENV=<env>"
elif (( sa_found == ${#ALL_SAS[@]} && deploy_missing == 0 )); then
  echo "  Step 4 has been done and you have what the deploy needs. Continue:"
  echo ""
  echo "    make up ENV=<env>"
else
  echo "  You cannot run step 4 — that is expected on a project you do not"
  echo "  administer. Someone with serviceAccountAdmin, projectIamAdmin and"
  echo "  serviceUsageAdmin has to run it once. Generate the request:"
  echo ""
  echo "    make omes-request ENV=<env>"
  echo ""
  if (( deploy_missing )); then
    echo "  It also asks for the $deploy_missing deploy role(s) you are missing above."
  fi
fi
echo ""
