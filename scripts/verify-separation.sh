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
if [[ -z "$PROJECT" || -z "$PREFIX" ]]; then
  echo "usage: $0 <project-id> <name-prefix>" >&2
  exit 64
fi

sa() { echo "sa-${PREFIX}-$1-1@${PROJECT}.iam.gserviceaccount.com"; }

fail=0
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
