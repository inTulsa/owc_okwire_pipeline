#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# What to ask a project admin for, on a call, in as few commands as possible.
#
# Not an email. Someone is at a keyboard and wants to know what to type, why,
# and when they can stop.
#
# The ask is deliberately scoped: it prints the gap, not the whole setup.
# Most of 01-admin-identities.sh needs no elevated rights, and telling an
# admin to grant roles the deploy account already holds makes the request
# look bigger than it is — which is how a two-minute task becomes a
# scheduling problem.
#
#   ./infra/gcloud/03-admin-request.sh owc-dpar-d --principal user:you@agency.ok.gov
# ---------------------------------------------------------------------------
set -uo pipefail

PROJECT=""; PREFIX=""; PRINCIPAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="${2:?}"; shift 2 ;;
    --principal) PRINCIPAL="${2:?}"; shift 2 ;;
    *)           PROJECT="$1"; shift ;;
  esac
done
[[ -n "$PROJECT" ]] || { echo "usage: $0 <project-id> [--prefix P] --principal MEMBER" >&2; exit 64; }
PREFIX="${PREFIX:-$PROJECT}"
if [[ -z "$PRINCIPAL" ]]; then
  acct=$(gcloud config get-value account 2>/dev/null)
  PRINCIPAL="user:${acct}"
fi

# shellcheck source=names.sh
source "$(dirname "${BASH_SOURCE[0]}")/names.sh"

REPO_URL="${REPO_URL:-https://github.com/inTulsa/owc_okwire_pipeline.git}"

missing_sa=0
for email in "${ALL_SAS[@]}"; do
  gcloud iam service-accounts describe "$email" --project "$PROJECT" >/dev/null 2>&1 || missing_sa=$((missing_sa+1))
done

cat <<TXT

================================================================================
  OWC data platform — one-time setup on $PROJECT
================================================================================

  Deploy account : $PRINCIPAL
  Still to create: $missing_sa of ${#ALL_SAS[@]} service accounts, and their IAM

WHY YOU ARE BEING ASKED
  Terraform is not allowed to create service accounts or write the project
  IAM policy. That was your feedback and this is us acting on it. Everything
  that needs those rights is collected into one script, run ONCE. After
  today nobody needs serviceAccountAdmin or projectIamAdmin again.

  The deploy account above already holds the ten resource-admin roles
  Terraform needs. It is missing exactly two:

      roles/iam.serviceAccountAdmin           to create the 6 accounts
      roles/resourcemanager.projectIamAdmin   to grant them their roles

  Pick either option below. They do the same thing.

--------------------------------------------------------------------------------
  OPTION A  —  grant for the call, we run it, you take it back  (4 commands)
--------------------------------------------------------------------------------

  1. You grant the two roles:

    gcloud projects add-iam-policy-binding $PROJECT \\
      --member $PRINCIPAL --role roles/iam.serviceAccountAdmin --condition=None

    gcloud projects add-iam-policy-binding $PROJECT \\
      --member $PRINCIPAL --role roles/resourcemanager.projectIamAdmin --condition=None

  2. We run it (about 60 seconds) and read the output back to you:

    make gcloud-admin ENV=dev

  3. You take the two roles back, on the same call:

    gcloud projects remove-iam-policy-binding $PROJECT \\
      --member $PRINCIPAL --role roles/iam.serviceAccountAdmin

    gcloud projects remove-iam-policy-binding $PROJECT \\
      --member $PRINCIPAL --role roles/resourcemanager.projectIamAdmin

  4. We prove the elevation is gone, and you watch it pass:

    make iam-check ENV=dev STRICT=1

  STRICT=1 FAILS if either role is still attached, so it is the receipt for
  step 3 — which is why it runs after the revoke, not before.

--------------------------------------------------------------------------------
  OPTION B  —  you run it yourself, nothing is granted to us
--------------------------------------------------------------------------------

  In your own Cloud Shell, on $PROJECT:

    git clone $REPO_URL owc && cd owc
    ./infra/gcloud/01-admin-identities.sh $PROJECT \\
        --prefix $PREFIX --principal $PRINCIPAL --dry-run

  That prints every command and changes nothing. Read it, then drop
  --dry-run to apply. It is idempotent — anything already correct is skipped.

--------------------------------------------------------------------------------
  WHAT GETS CREATED, EITHER WAY
--------------------------------------------------------------------------------

  6 service accounts   one per job, so each holds only what it needs. The
                       web scraper cannot read the Snowflake password; the
                       Snowflake job cannot write the scraper's cache.
  10 project bindings  bigquery.jobUser / logging.logWriter /
                       monitoring.metricWriter across those accounts. Nothing
                       broader.
  5 actAs grants       so the deploy account may attach those identities to
                       Cloud Run and Cloud Scheduler jobs. Per-account, not
                       project-wide.
  1 tokenCreator       for Google's BigQuery Data Transfer agent, on one
                       account, so a scheduled query can run as it.
  4 API enables        of the 16 needed; 12 are already on.
  2 GCS buckets        Terraform state, and a source mirror.

  No roles/owner, no roles/editor, no custom roles, nothing outside
  $PROJECT.

  Hosting Terraform state yourselves instead? Tell us the bucket and we
  point the config at it; the script then skips creating one.

================================================================================
TXT
