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

# Prod pins the ref: only main can deploy. Combined with the repository
# condition in the WIF provider, this is what stops any other repo — or any
# branch in this one — from minting tokens for this project.
allowed_refs = ["refs/heads/main"]

alert_emails = ["owc-data-alerts@tulsaforyou.com"]

snowflake_user = "REPLACE_ME@tulsaforyou.com"

# Required, supplied by the deploy workflow with the digest it just promoted
# from dev. No default on purpose.
# image_digest = "us-central1-docker.pkg.dev/owc-data-prod/okw-images/owcdata@sha256:..."

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
#     --member=serviceAccount:okw-deployer-prod@owc-data-prod.iam.gserviceaccount.com \
#     --role=roles/billing.costsManager
billing_budget_amount = 0
# billing_account     = "0X0X0X-0X0X0X-0X0X0X"
