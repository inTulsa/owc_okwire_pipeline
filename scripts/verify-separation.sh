#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Verify the identity separation is real, not aspirational.
#
# This was a block of shell in docs/03-gcp-setup.md that you pasted into a
# terminal. It is a script now because that block had four independent bugs,
# and three of them made it print OK while checking nothing:
#
#   1. It used $PREFIX without setting it, so every resource name came out
#      as "gcs--enrollment-state-1" and every lookup 404'd.
#   2. It grepped for the Cloud Run JOB name (cr-...) where the IAM policy
#      contains the SERVICE ACCOUNT (sa-...@...). That string can never
#      appear, so the check passed unconditionally.
#   3. `cmd | grep -q X && echo PROBLEM || echo OK` prints OK when the
#      command FAILS — permission denied, 404, typo, all "OK".
#   4. zsh does not treat # as a comment interactively (INTERACTIVE_COMMENTS
#      is off by default), so pasting it also spewed "command not found: #".
#
# The lesson in 2 and 3 is the same: a check that cannot fail is worse than
# no check, because it is reassuring. So every assertion below separates "the
# command worked" from "the answer was no", and there is a POSITIVE CONTROL
# at the end which must find a grant it knows exists. If the control fails,
# the negative results above it are meaningless and this exits non-zero.
# ---------------------------------------------------------------------------
set -uo pipefail

PROJECT="${1:-}"
PREFIX="${2:-}"
# Passed in rather than defaulted: the Cloud Run jobs live in one region, and
# a wrong guess here reports "could not read the policy" for a job that is
# fine, which is the kind of false alarm this script exists not to produce.
REGION="${3:-us-central1}"
if [[ -z "$PROJECT" || -z "$PREFIX" ]]; then
  echo "usage: $0 <project-id> <name-prefix> [region]" >&2
  exit 64
fi

sa() { echo "sa-${PREFIX}-$1-1@${PROJECT}.iam.gserviceaccount.com"; }

fail=0

# Is MEMBER listed under ROLE in this policy? Not "do both strings appear" —
# that is what the loose grep below does for the NEGATIVE checks, where
# "appears nowhere" is a sound thing to test with it. A positive assertion
# needs the member to be in that role's binding specifically, or a scheduler
# holding some unrelated role would read as "can invoke".
BINDING_MATCHER='
import json, sys
role, member = sys.argv[1], sys.argv[2]
policy = json.load(sys.stdin)
sys.exit(0 if any(
    b.get("role") == role and member in b.get("members", [])
    for b in policy.get("bindings", [])
) else 1)
'
binding_has() { python3 -c "$BINDING_MATCHER" "$2" "$3" <<<"$1"; }
pass() { printf '  OK       %s\n' "$1"; }
bad()  { printf '  PROBLEM  %s\n' "$1"; fail=1; }
err()  { printf '  ERROR    %s\n' "$1"; fail=1; }

echo ""
echo "Identity separation — $PROJECT (prefix $PREFIX)"
echo ""

# --- the enrollment SA must NOT be able to read the Snowflake secret -------
# Its source is a public webpage; it has no business holding this.
if policy=$(gcloud secrets get-iam-policy "sm-${PREFIX}-snowflake-password-1" \
      --project="$PROJECT" --format=json 2>&1); then
  if grep -q "$(sa enrollment)" <<<"$policy"; then
    bad "enrollment CAN read the Snowflake secret"
  else
    pass "enrollment has no access to the Snowflake secret"
  fi
else
  err "could not read the secret's IAM policy: $(tail -1 <<<"$policy")"
fi

# --- the lightcast SA must NOT be able to write the scrape cache -----------
if policy=$(gcloud storage buckets get-iam-policy "gs://gcs-${PREFIX}-enrollment-state-1" \
      --project="$PROJECT" --format=json 2>&1); then
  if grep -q "$(sa lightcast)" <<<"$policy"; then
    bad "lightcast CAN write the enrollment scrape cache"
  else
    pass "lightcast has no access to the enrollment state bucket"
  fi
else
  err "could not read the state bucket's IAM policy: $(tail -1 <<<"$policy")"
fi

# --- PowerBI reads owc_marts and nothing else ------------------------------
# Not owc_staging (unvalidated data), not owc_ops (the run manifest).
for ds in owc_staging owc_ops; do
  if meta=$(bq show --format=prettyjson "${PROJECT}:${ds}" 2>&1); then
    if grep -q "$(sa powerbi)" <<<"$meta"; then
      bad "PowerBI has a grant on $ds"
    else
      pass "PowerBI has no grant on $ds"
    fi
  else
    err "could not read dataset $ds: $(tail -1 <<<"$meta")"
  fi
done

# --- the scheduler MUST be able to invoke both jobs ------------------------
#
# Every other assertion here is negative — X cannot reach Y. This one is the
# grant the schedule actually runs on, and nothing checked it. Its absence is
# silent until Cloud Scheduler fires and Cloud Logging records
#
#   PERMISSION_DENIED ... jobs/cr-<prefix>-<pipeline>-1:run   403
#
# In prod that is 06:00 on the 1st, unattended, a month after the deploy.
for job in "cr-${PREFIX}-lightcast-1" "cr-${PREFIX}-enrollment-1"; do
  if policy=$(gcloud run jobs get-iam-policy "$job" \
        --region "$REGION" --project "$PROJECT" --format=json 2>&1); then
    if binding_has "$policy" roles/run.invoker "serviceAccount:$(sa scheduler)"; then
      pass "scheduler can invoke $job"
    else
      bad "scheduler CANNOT invoke $job — the schedule will 403 when it fires"
      bad "  gcloud run jobs add-iam-policy-binding $job \\"
      bad "    --region $REGION --project $PROJECT \\"
      bad "    --member serviceAccount:$(sa scheduler) --role roles/run.invoker"
    fi
  else
    err "could not read $job's IAM policy: $(tail -1 <<<"$policy")"
  fi
done

# --- POSITIVE CONTROL ------------------------------------------------------
# Every assertion above passes by NOT finding a string. That is exactly the
# shape that silently passed for months when the string was wrong, so prove
# the method can still find one: PowerBI must have dataViewer on owc_marts.
if meta=$(bq show --format=prettyjson "${PROJECT}:owc_marts" 2>&1); then
  if grep -q "$(sa powerbi)" <<<"$meta"; then
    pass "control: PowerBI IS granted on owc_marts (so the checks above can detect a grant)"
  else
    err "control FAILED: PowerBI has no grant on owc_marts either. Every 'OK' above is meaningless — the lookup is not finding grants that exist."
  fi
else
  err "control could not read owc_marts: $(tail -1 <<<"$meta")"
fi

echo ""
if [[ "$fail" -ne 0 ]]; then
  echo "Separation NOT verified. See docs/01-architecture.md ADR-006."
  exit 1
fi
echo "Separation verified."
