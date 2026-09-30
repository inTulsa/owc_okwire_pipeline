#!/usr/bin/env bash
# Fail early and clearly when the gcloud CLI has no usable credentials.
#
# Exists because every "does this resource exist?" check in the Makefile runs
# a gcloud command and treats a non-zero exit as "absent". When the CLI token
# expires, those checks confidently report the wrong cause — an expired token
# became "no image found, build one first" and "the secret container does not
# exist yet, run tf-bootstrap", both of which point at work that is already
# done. A diagnostic that lies is worse than one that says nothing.
#
# Note gcloud CLI credentials and Application Default Credentials are
# SEPARATE. Terraform uses ADC and can keep working while the CLI is expired,
# which is exactly how this stays confusing.
set -uo pipefail

if gcloud auth print-access-token >/dev/null 2>&1; then
  # Credentials are fine. Now: is this shell wearing the deploy identity?
  #
  # A new Cloud Shell session starts without it, because `make env-exports`
  # sets it per-shell. Everything then runs as the person, who deliberately
  # holds almost nothing — and the first failure is whatever happens to need
  # actAs, reported against a numeric service account id:
  #
  #   PERMISSION_DENIED: caller does not have permission to act as service
  #   account projects/<p>/serviceAccounts/107658414795578711517
  #
  # That names neither the account nor the cause. $1 is the deploy account
  # the caller SHOULD be impersonating; empty means the caller did not pass
  # one and this check is skipped.
  want="${1:-}"
  if [[ -n "$want" && -z "${CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT:-}" ]]; then
    if gcloud iam service-accounts describe "$want" >/dev/null 2>&1 \
       || [[ -n "${OWC_DEPLOY_SA_EXISTS:-}" ]]; then
      {
        echo ""
        echo "This shell is NOT impersonating the deploy account."
        echo ""
        echo "  running as    : $(gcloud config get-value account 2>/dev/null)"
        echo "  should act as : $want"
        echo ""
        echo "Your own account holds one binding in this project —"
        echo "tokenCreator on that service account — so anything needing"
        echo "actAs or a resource-admin role will fail, and the error will"
        echo "name a numeric service account id rather than this cause."
        echo ""
        echo "A new Cloud Shell session always starts like this. Fix:"
        echo "  eval \"\$(make -s env-exports ENV=<env>)\""
        echo ""
        echo "To deploy as yourself instead (a project you own), unset the"
        echo "check: OWC_ALLOW_NO_IMPERSONATION=1"
        echo ""
      } >&2
      [[ -n "${OWC_ALLOW_NO_IMPERSONATION:-}" ]] || exit 1
    fi
  fi
  exit 0
fi

{
  echo ""
  echo "The gcloud CLI has no usable credentials — its token has expired."
  echo ""
  echo "Nothing is wrong with your project. Resource checks that run gcloud"
  echo "will report things as missing when they are not."
  echo ""
  echo "Fix:"
  echo "  gcloud auth login"
  echo ""
  echo "Terraform uses Application Default Credentials, which are separate and"
  echo "may still be valid. If Terraform also fails, refresh those too:"
  echo "  gcloud auth application-default login"
  echo ""
} >&2
exit 1
