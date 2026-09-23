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
  FOR THE PROJECT ADMIN — about 2 minutes. You do not need this repo.
================================================================================

  Grant these two roles to  $PRINCIPAL  on  $PROJECT :

      Service Account Admin      roles/iam.serviceAccountAdmin
      Project IAM Admin          roles/resourcemanager.projectIamAdmin

  Console:  IAM & Admin  >  IAM  >  Grant access
  Or CLI:

    gcloud projects add-iam-policy-binding $PROJECT \\
      --member $PRINCIPAL --role roles/iam.serviceAccountAdmin --condition=None

    gcloud projects add-iam-policy-binding $PROJECT \\
      --member $PRINCIPAL --role roles/resourcemanager.projectIamAdmin --condition=None

  Tell us. We run one command, takes about a minute, and read it back.

  Then take both roles away again — same page, or:

    gcloud projects remove-iam-policy-binding $PROJECT \\
      --member $PRINCIPAL --role roles/iam.serviceAccountAdmin

    gcloud projects remove-iam-policy-binding $PROJECT \\
      --member $PRINCIPAL --role roles/resourcemanager.projectIamAdmin

  We then run a check, in front of you, that FAILS if either role is still
  attached. That is your receipt that the elevation is gone.

  That is the whole ask. Everything below is detail if you want it.

================================================================================

WHY
  Terraform is not allowed to create service accounts or write the project
  IAM policy — that was your feedback and this is us acting on it. So
  everything needing those rights is collected into one script, run once.
  After today nobody needs either role again.

  $PRINCIPAL already holds the ten resource-admin roles the deploy needs.
  The two above are the only gap.

WHAT THE ONE COMMAND CREATES
  6 service accounts   one per job, so each holds only what it needs. The web
                       scraper cannot read the Snowflake password; the
                       Snowflake job cannot write the scraper's cache.
  10 project bindings  bigquery.jobUser / logging.logWriter /
                       monitoring.metricWriter across those accounts.
  5 actAs grants       so the deploy account may attach those identities to
                       Cloud Run and Cloud Scheduler jobs. Per-account, not
                       project-wide.
  1 tokenCreator       for Google's BigQuery Data Transfer agent, on one
                       account.
  API enables          of the 16 needed.
  2 GCS buckets        Terraform state, and a source mirror.

  No roles/owner, no roles/editor, no custom roles, nothing outside
  $PROJECT. Still to create here: $missing_sa of ${#ALL_SAS[@]} service accounts.

IF YOU WOULD RATHER RUN IT YOURSELF
  Nothing is granted to us at all. In your own Cloud Shell on $PROJECT:

    git clone $REPO_URL owc && cd owc
    ./infra/gcloud/01-admin-identities.sh $PROJECT \\
        --prefix $PREFIX --principal $PRINCIPAL --dry-run

  That prints every command and changes nothing. Drop --dry-run to apply.
  Idempotent: anything already correct is skipped.

HOSTING TERRAFORM STATE YOURSELVES?
  Tell us the bucket name and we point the config at it; the script then
  skips creating one.

================================================================================
TXT
