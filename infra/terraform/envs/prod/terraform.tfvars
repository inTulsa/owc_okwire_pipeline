# prod  —  OMES project owc-dpar-p
#
# Do NOT point this environment at a test project. schedulers_paused = false
# here, so an apply creates LIVE Cloud Scheduler jobs that fire the monthly
# schedule — 41 Snowflake queries billed to Lightcast, from whatever project
# you aimed it at. Test with envs/dev; see that file's header.
project_id   = "owc-dpar-p"
name_prefix  = "owc-dpar-p"
state_bucket = "gcs-owc-dpar-p-tfstate-1"
region       = "us-central1"
location     = "US"
# Read only when enable_wif = true, which it is not. Kept so the value
# does not have to be rediscovered when OMES federates their own instance.
github_repository = "inTulsa/owc_okwire_pipeline"

# Inert while enable_wif = false. Kept for when OMES federates their own
# instance: prod pins the ref so only the prod branch can deploy here, which
# combined with the provider's repository condition is what would stop any
# other repo — or any branch in this one — from minting tokens for it.
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

# ---------------------------------------------------------------------------
# The OMES split. Terraform creates RESOURCES; it does not create identities
# and it never touches the project IAM policy.
#
#   "your terraform should not write IAM on each run ... projectIamAdmin and
#    serviceAccountAdmin is too much for terraform process, we should be able
#    to manual create the resources needed, and then use lower permissions on
#    the additional runs"          -- Stephen Jones, OMES
#
# Run infra/gcloud/01-admin-identities.sh once, with an account that holds
# serviceAccountAdmin and projectIamAdmin. It creates the six service
# accounts, their project-level roles, the sixteen API enables, and the state
# bucket. Everything after it runs with the ten resource-admin roles in
# infra/gcloud/names.sh and nothing else.
#
# Flip any of these to true only alongside re-granting the matching role —
# `make iam-check ENV=prod` prints exactly which one.
# ---------------------------------------------------------------------------
# no google_service_account, no google_project_iam_member
manage_identities = false
# no google_project_service
manage_apis = false
# no GitHub WIF pool, no deployer service account, no thirteen-role grant
enable_wif = false
