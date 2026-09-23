# dev  —  OMES project owc-dpar-d
#
# TESTING AGAINST YOUR OWN PROJECT
#
# Change project_id, name_prefix and state_bucket below, AND the bucket
# literal in backend.tf. The backend block cannot read a variable, so that is
# the one value living in two files; a mismatch surfaces as
# "storage: bucket doesn't exist", which is not what it means.
#
# Do it on a throwaway branch rather than editing and reverting. dev and main
# then never carry a test project's values, and cleanup is deleting the
# branch:
#
#   git switch -c test/<project>     # edit both files, commit, push
#   git clone -b test/<project> ...  # in Cloud Shell
#
# Command-line -var overrides are NOT sufficient. `make up` drives
# gcloud-admin, source-push, iam-check, build, set-image and smoke, and every
# one of those reads project_id and name_prefix out of THIS file. -var reaches
# terraform only, so you would create identities in one project and apply to
# another.
#
# Use envs/dev, not envs/prod: prod sets schedulers_paused = false, so a test
# apply there creates LIVE schedulers that fire prod's monthly schedule at
# Lightcast's warehouse.
project_id = "owc-dpar-d"
region     = "us-central1"
location   = "US"

# A distribution list, so people join and leave without a Terraform change.
alert_emails = ["gabriel.torianyk@tulsaforyou.com"]

snowflake_user = "analytics@tulsaforyou.com"

# Required. Build first: `make build ENV=dev`, then pass the digest it prints.
# CI supplies this with -var; it has no default on purpose.
# image_digest = "us-central1-docker.pkg.dev/owc-dpar-d/ar-owc-dpar-d-images-1/owcdata@sha256:..."

billing_budget_amount = 0
# billing_account     = "0X0X0X-0X0X0X-0X0X0X"
