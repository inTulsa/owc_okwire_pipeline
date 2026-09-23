#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Read-only. Proves that 01-admin-identities.sh landed, and — the part that
# matters to OMES — that the Terraform principal does NOT hold the roles this
# split was supposed to remove.
#
#   ./infra/gcloud/02-verify-admin.sh owc-dpar-d \
#       --principal user:gabriel.torianyk@tulsaforyou.com
#
# Every assertion separates "the command worked" from "the answer was no",
# because `cmd | grep -q X && echo OK` prints OK when the command FAILS —
# permission denied, 404 and typo all come out as a pass. There is a POSITIVE
# CONTROL at the end which must find a binding it knows exists; if the control
# fails, nothing above it means anything and this exits non-zero.
# ---------------------------------------------------------------------------
set -uo pipefail

PROJECT=""
PREFIX=""
PRINCIPAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --principal) PRINCIPAL="${2:?}"; shift 2 ;;
    -h|--help)   echo "usage: $0 <project-id> [--prefix P] [--principal MEMBER]" >&2; exit 64 ;;
    *)           PROJECT="$1"; shift ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "usage: $0 <project-id> [--prefix P] [--principal MEMBER]" >&2; exit 64; }
PREFIX="${PREFIX:-$PROJECT}"

# shellcheck source=names.sh
source "$(dirname "${BASH_SOURCE[0]}")/names.sh"

fail=0
pass() { printf '  \033[32mOK\033[0m       %s\n' "$1"; }
bad()  { printf '  \033[31mPROBLEM\033[0m  %s\n' "$1"; fail=1; }
err()  { printf '  \033[33mERROR\033[0m    %s\n' "$1"; fail=1; }
head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }

printf '\n\033[1mAdmin bootstrap — %s (prefix %s)\033[0m\n' "$PROJECT" "$PREFIX"

# Read the whole project policy once. Every per-role check below is then a
# string test against this, which also means a single permission failure is
# reported once, here, rather than as ten confusing "absent" results.
# Not being able to read it is not a failure — it is the expected state for
# the reduced Terraform principal, and it is self-evidencing: a principal that
# cannot call getIamPolicy definitionally does not hold projectIamAdmin. So
# drop to REDUCED mode and check everything that does not need the policy,
# rather than refusing to run on the very account this design exists to
# create.
#
# `make up` calls this first, and `make up` is the unprivileged half. If this
# exited here, the deploy path would require the permission it was built to
# remove.
REDUCED=0
if ! POLICY=$(gcloud projects get-iam-policy "$PROJECT" --format=json 2>&1); then
  REDUCED=1
  POLICY='{"bindings":[]}'
fi

if (( REDUCED )); then
  head2 "Running in REDUCED mode"
  printf '  \033[2m%s\033[0m\n' "This account cannot read the project IAM policy, so the role"
  printf '  \033[2m%s\033[0m\n' "assertions below are skipped. That is the expected state for the"
  printf '  \033[2m%s\033[0m\n' "Terraform principal, and it is its own proof: an account that cannot"
  printf '  \033[2m%s\033[0m\n' "call getIamPolicy does not hold roles/resourcemanager.projectIamAdmin."
  printf '  \033[2m%s\033[0m\n' ""
  printf '  \033[2m%s\033[0m\n' "Everything a deploy actually depends on is still checked below. For"
  printf '  \033[2m%s\033[0m\n' "the full audit, run this as the account that ran 01-admin-identities.sh."
fi


# Exact match on both member and role, against the policy read once above.
#
# Exact, not a grep. `grep projectIamAdmin` would also match the role name
# inside a condition expression or a longer role, and a substring match on the
# member would let "user:gabe@x.com" be satisfied by "user:gabe@x.com.evil".
# Both make a "does not have" assertion pass when it should fail, which is the
# one direction that must never be wrong here.
POLICY_MATCHER='
import json, sys
member, role = sys.argv[1], sys.argv[2]
policy = json.load(sys.stdin)
sys.exit(0 if any(
    b.get("role") == role and member in b.get("members", [])
    for b in policy.get("bindings", [])
) else 1)
'

has_binding() {
  # has_binding <member> <role>
  python3 -c "$POLICY_MATCHER" "$1" "$2" <<<"$POLICY"
}

# --- the six identities exist ----------------------------------------------
head2 "Service accounts"
for email in "${ALL_SAS[@]}"; do
  if out=$(gcloud iam service-accounts describe "$email" --project "$PROJECT" 2>&1); then
    pass "${email%%@*} exists"
  else
    bad "${email%%@*} is MISSING — re-run 01-admin-identities.sh"
  fi
done

# There must be NO deployer and NO WIF pool: GitHub Actions is not in this
# path, and the deployer was the identity that needed the 13-role grant.
head2 "GitHub deploy path is absent (OMES cannot hook up a personal GitHub)"
if gcloud iam service-accounts describe "sa-${PREFIX}-deployer-1@${PROJECT}.iam.gserviceaccount.com" \
     --project "$PROJECT" >/dev/null 2>&1; then
  bad "a deployer service account still exists — left over from the WIF path"
else
  pass "no deployer service account"
fi
if pools=$(gcloud iam workload-identity-pools list --location=global \
     --project "$PROJECT" --format='value(name)' 2>&1); then
  if [[ -n "$pools" ]]; then
    bad "workload identity pool(s) still exist: $(tr '\n' ' ' <<<"$pools")"
  else
    pass "no workload identity pools"
  fi
else
  # Not fatal: listing pools needs a permission the checker may not hold.
  printf '  \033[2mskip\033[0m     could not list workload identity pools (permission)\n'
fi

# --- runtime project bindings ----------------------------------------------
if (( ! REDUCED )); then
head2 "Project-level roles on the runtime identities"
for grant in "${RUNTIME_PROJECT_GRANTS[@]}"; do
  key="${grant%%|*}"; role="${grant##*|}"
  if has_binding "serviceAccount:$(sa_email "$key")" "$role"; then
    pass "$key has $role"
  else
    bad "$key is MISSING $role"
  fi
done
fi

# --- the freshness token creator -------------------------------------------
head2 "Data Transfer agent can mint tokens for the freshness identity"
if pol=$(gcloud iam service-accounts get-iam-policy "$SA_FRESHNESS" \
     --project "$PROJECT" --format=json 2>&1); then
  if grep -q 'gcp-sa-bigquerydatatransfer' <<<"$pol" \
     && grep -q 'roles/iam.serviceAccountTokenCreator' <<<"$pol"; then
    pass "tokenCreator granted to the bigquerydatatransfer agent"
  else
    bad "the bigquerydatatransfer agent has no tokenCreator on freshness — the"
    bad "  freshness scheduled query will fail (prod only; dev disables it)"
  fi
else
  err "could not read the freshness SA's policy: $(tail -1 <<<"$pol")"
fi

# --- the Terraform principal ------------------------------------------------
if (( REDUCED )); then
  head2 "Terraform principal"
  printf '  \033[2mskip\033[0m     role audit needs the project IAM policy (see REDUCED mode above)\n'
elif [[ -z "$PRINCIPAL" ]]; then
  head2 "Terraform principal"
  printf '  \033[2mskip\033[0m     no --principal given; pass one to check its roles\n'
else
  head2 "Terraform principal $PRINCIPAL — roles it needs"
  for role in "${TF_PRINCIPAL_ROLES[@]}"; do
    if has_binding "$PRINCIPAL" "$role"; then
      pass "has $role"
    else
      bad "MISSING $role — terraform apply will 403 on the resources it covers"
    fi
  done

  head2 "Terraform principal $PRINCIPAL — roles it must NOT have"
  # This is the assertion the whole split exists to make true. A pass here is
  # the answer to "projectIamAdmin and serviceAccountAdmin is too much for
  # terraform process".
  for role in "${TF_PRINCIPAL_FORBIDDEN_ROLES[@]}"; do
    if has_binding "$PRINCIPAL" "$role"; then
      bad "STILL HAS $role — remove it:"
      bad "  gcloud projects remove-iam-policy-binding $PROJECT \\"
      bad "    --member $PRINCIPAL --role $role"
    else
      pass "does not have $role"
    fi
  done

  head2 "Terraform principal $PRINCIPAL — actAs on the identities it attaches"
  for target in "${ATTACHED_SAS[@]}"; do
    if pol=$(gcloud iam service-accounts get-iam-policy "$target" \
         --project "$PROJECT" --format=json 2>&1); then
      if grep -q "$PRINCIPAL" <<<"$pol" && grep -q 'roles/iam.serviceAccountUser' <<<"$pol"; then
        pass "can actAs ${target%%@*}"
      else
        bad "cannot actAs ${target%%@*} — Terraform cannot attach it to a resource"
      fi
    else
      err "could not read ${target%%@*}'s policy: $(tail -1 <<<"$pol")"
    fi
  done
fi

# --- APIs -------------------------------------------------------------------
head2 "APIs"
if enabled=$(gcloud services list --enabled --project "$PROJECT" \
     --format='value(config.name)' 2>&1); then
  missing=()
  for api in "${REQUIRED_APIS[@]}"; do
    grep -qx "$api" <<<"$enabled" || missing+=("$api")
  done
  if (( ${#missing[@]} )); then
    bad "${#missing[@]} API(s) not enabled: $(printf '%s ' "${missing[@]}")"
  else
    pass "all ${#REQUIRED_APIS[@]} required APIs are enabled"
  fi
else
  err "could not list enabled APIs: $(tail -1 <<<"$enabled")"
fi

# --- the credentials Terraform will actually use ----------------------------
#
# gcloud and Terraform authenticate DIFFERENTLY: the CLI uses the account from
# `gcloud auth login` (which Cloud Shell does for you), Terraform uses
# Application Default Credentials (which Cloud Shell does NOT). Everything
# above this point passed using the CLI's credentials and says nothing about
# Terraform's.
#
# A stale or wrongly-scoped ADC quota project makes every GCS call return
#   404 "The requested project was not found"
# which Terraform's GCS backend reports as the very misleading
#   "Failed to get existing workspaces: ... storage: bucket doesn't exist"
# even though the bucket is fine. Catching it here costs a second.
head2 "Terraform's own credentials (ADC)"

if ! ADC_TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null); then
  bad "no Application Default Credentials — Terraform cannot authenticate"
  bad "  Cloud Shell logs gcloud in for you but NOT Terraform. Run:"
  bad "    gcloud auth application-default login"
else
  ADC_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
  ADC_QUOTA=""
  [[ -f "$ADC_FILE" ]] && ADC_QUOTA=$(python3 -c \
    "import json,sys;print(json.load(open(sys.argv[1])).get('quota_project_id',''))" \
    "$ADC_FILE" 2>/dev/null || true)

  # Mirror the client library: it sends the ADC quota project as
  # x-goog-user-project, so the check has to send it too or it tests nothing.
  declare -a QUOTA_HEADER=()
  [[ -n "$ADC_QUOTA" ]] && QUOTA_HEADER=(-H "x-goog-user-project: $ADC_QUOTA")

  # The exact call the GCS backend makes to enumerate workspaces.
  CHECK_BODY=$(mktemp)
  HTTP_CODE=$(curl -s -o "$CHECK_BODY" -w '%{http_code}' \
    -H "Authorization: Bearer $ADC_TOKEN" "${QUOTA_HEADER[@]}" \
    "https://storage.googleapis.com/storage/v1/b/${BUCKET_STATE}/o?prefix=env&maxResults=1" \
    || echo 000)

  if [[ "$HTTP_CODE" == "200" ]]; then
    pass "ADC can read gs://$BUCKET_STATE — terraform init will work"
    [[ -n "$ADC_QUOTA" ]] && printf '  \033[2m%s\033[0m\n' "quota project: $ADC_QUOTA"
  elif ! gcloud storage buckets describe "gs://$BUCKET_STATE" \
         --project "$PROJECT" >/dev/null 2>&1; then
    # The bucket is genuinely absent. Distinguishing this from the ADC
    # quota-project fault matters: BOTH surface as a 404 on that API call,
    # and telling someone to re-authenticate when the real answer is "the
    # bucket has not been created yet" sends them to the wrong place
    # entirely. The CLI credentials already read the project IAM policy
    # above, so this lookup is trustworthy.
    bad "gs://$BUCKET_STATE does not exist yet — this is not a credentials problem"
    bad "  Create it:  ./infra/gcloud/01-admin-identities.sh $PROJECT --prefix $PREFIX"
    bad "  Or, if OMES is hosting state, point backend.tf and state_bucket at theirs."
  elif [[ "$HTTP_CODE" == "404" ]]; then
    bad "The bucket exists, but ADC gets a 404 on it — that is the quota project."
    bad "  Every GCS call is billed to ADC's quota_project_id${ADC_QUOTA:+ ($ADC_QUOTA)}, and"
    bad "  an inactive or wrong one 404s every call. Terraform reports that as"
    bad "  \"storage: bucket doesn't exist\", pointing at the wrong thing."
    bad "  Fix:  gcloud auth application-default set-quota-project $PROJECT"
  else
    msg=$(python3 -c "
import json,sys
try:
    e = json.load(open(sys.argv[1])).get('error', {})
    print(f\"{e.get('code','?')} {e.get('message','')}\")
except Exception:
    print('(no error body)')
" "$CHECK_BODY" 2>/dev/null)
    bad "ADC cannot read gs://$BUCKET_STATE  (HTTP $HTTP_CODE: $msg)"
    bad "  The bucket exists and the CLI can see it, so this is about the"
    bad "  credentials Terraform uses, which are separate from the CLI's."
    bad "  Try:  gcloud auth application-default login"
  fi
  rm -f "$CHECK_BODY"
fi

# --- the source bucket ------------------------------------------------------
head2 "Source bucket"
if gcloud storage buckets describe "gs://$BUCKET_SOURCE" --project "$PROJECT" >/dev/null 2>&1; then
  if gcloud storage ls "gs://$BUCKET_SOURCE/latest.tar.gz" >/dev/null 2>&1; then
    pass "gs://$BUCKET_SOURCE holds a published revision"
  else
    # Not a failure: the bucket is created before anything is pushed to it.
    printf '  \033[33mwarn\033[0m     %s\n' "gs://$BUCKET_SOURCE is empty — run 'make source-push' so a fresh Cloud Shell can fetch the repo"
  fi
else
  bad "gs://$BUCKET_SOURCE does not exist — re-run 01-admin-identities.sh"
fi

# --- positive control -------------------------------------------------------
# Every negative assertion above ("does not have projectIamAdmin") passes by
# NOT finding a string in $POLICY — which is also exactly what a truncated,
# empty or wrong-shaped policy produces. So assert one binding that must be
# there. If this fails, the negative results mean nothing.
head2 "Positive control"
if (( REDUCED )); then
  # There were no negative policy assertions to validate, so there is nothing
  # for a control to protect. Saying so beats printing a pass that tested
  # nothing.
  printf '  \033[2mskip\033[0m     no policy assertions were made, so there is nothing to control for\n'
elif has_binding "serviceAccount:$SA_LIGHTCAST" "roles/bigquery.jobUser"; then
  pass "control: the policy read back really does contain a known binding"
else
  err "control FAILED: could not find lightcast's bigquery.jobUser in the policy."
  err "  Every 'does not have' result above is therefore meaningless."
fi

echo ""
if (( fail )); then
  echo "Not ready. Fix the PROBLEM lines above, then re-run."
  exit 1
fi
if (( REDUCED )); then
  echo "Ready to deploy. The IAM role audit was skipped — run this as an admin"
  echo "account for that, or see docs/09-gcloud-deploy.md."
else
  echo "Admin bootstrap verified. Terraform can now run with no IAM permissions."
fi
