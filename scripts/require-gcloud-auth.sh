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
