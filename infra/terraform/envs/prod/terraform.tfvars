# prod  —  OMES project owc-dpar-p
#
# See envs/dev/terraform.tfvars for how to point an apply at a different
# project without editing the committed handoff values.
project_id        = "owc-dpar-p"
name_prefix       = "owc-dpar-p"
state_bucket      = "gcs-owc-dpar-p-tfstate-1"
region            = "us-central1"
location          = "US"
github_repository = "inTulsa/owc_okwire_pipeline"

# Prod pins the ref: only the prod branch can deploy here. Combined with the
# repository condition in the WIF provider, this is what stops any other
# repo — or any branch in this one — from minting tokens for this project.
#
# Branch == environment, so this is also the teeth behind the promotion gate:
# reaching prod requires a merge into `prod`, which is a reviewable PR.
allowed_refs = ["refs/heads/prod"]

alert_emails = ["owc-data-alerts@tulsaforyou.com"]

snowflake_user = "REPLACE_ME@tulsaforyou.com"

# Required, supplied by the deploy workflow with the digest it just promoted
# from dev. No default on purpose.
# image_digest = "us-central1-docker.pkg.dev/owc-dpar-p/ar-owc-dpar-p-images-1/owcdata@sha256:..."

# 0 disables the budget resource entirely (modules/platform/monitoring.tf
# gates it on amount > 0 AND a billing account).
#
# Deliberate: google_billing_budget lives on the BILLING ACCOUNT, not the
# project, so Terraform cannot grant the deployer access to it the way it
# grants everything else here — it would need roles/billing.costsManager
# added by hand at the billing-account level, outside this repo's blast
# radius. CI would then 403 on every refresh of the budget.
#
# To enable it later: set an amount, uncomment billing_account, and grant
#   gcloud billing accounts add-iam-policy-binding <ACCOUNT_ID> \
#     --member=serviceAccount:sa-owc-dpar-p-deployer-1@owc-dpar-p.iam.gserviceaccount.com \
#     --role=roles/billing.costsManager
billing_budget_amount = 0
# billing_account     = "0X0X0X-0X0X0X-0X0X0X"
