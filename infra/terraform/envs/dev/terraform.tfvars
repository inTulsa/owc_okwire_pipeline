# dev  —  OMES project owc-dpar-d
#
# Testing against a different project (e.g. your own GCP account) does not
# mean editing this file. Override at the command line so the handoff values
# stay committed and correct:
#
#   make tf-apply ENV=dev TF_ARGS="-var=project_id=my-proj -var=name_prefix=my-proj -var=state_bucket=my-tfstate"
#
# and point the backend at your own bucket once, at init:
#
#   terraform -chdir=infra/terraform/envs/dev init -reconfigure -backend-config="bucket=my-tfstate"
project_id        = "owc-dpar-td"
name_prefix       = "owc-dpar-td"
state_bucket      = "gcs-owc-dpar-td-tfstate-1"
region            = "us-central1"
location          = "US"
github_repository = "inTulsa/owc_okwire_pipeline"

# Deliberately open. Prod pins refs/heads/prod, but dev must accept ANY ref:
# ci.yml runs the pull-request plan as this environment's deployer, and a PR
# head is an arbitrary ref. Pinning dev to refs/heads/dev would fail every
# plan on every pull request.
allowed_refs = []

# A distribution list, so people join and leave without a Terraform change.
alert_emails = ["gabriel.torianyk@tulsaforyou.com"]

snowflake_user = "analytics@tulsaforyou.com"

# Required. Build first: `make build ENV=dev`, then pass the digest it prints.
# CI supplies this with -var; it has no default on purpose.
# image_digest = "us-central1-docker.pkg.dev/owc-dpar-d/ar-owc-dpar-d-images-1/owcdata@sha256:..."

billing_budget_amount = 0
# billing_account     = "0X0X0X-0X0X0X-0X0X0X"
