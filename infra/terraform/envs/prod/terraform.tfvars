# prod  —  OMES project owc-dpar-p
#
# Do NOT point this environment at a test project. schedulers_paused = false
# here, so an apply creates LIVE Cloud Scheduler jobs that fire the monthly
# schedule — 35 Snowflake queries billed to Lightcast, from whatever project
# you aimed it at. Test with envs/dev; see that file's header.
project_id = "owc-dpar-p"
region     = "us-central1"
location   = "US"

# A distribution list, so people join and leave without a Terraform change.
alert_emails = ["gurtaj.singh@workforce.ok.gov"]

snowflake_user = "analytics@tulsaforyou.com"

# Required. `make up ENV=prod` builds the image and passes the digest it
# prints; it has no default on purpose.
# image_digest = "us-central1-docker.pkg.dev/owc-dpar-p/ar-owc-dpar-p-images-1/owcdata@sha256:..."

# 0 disables the budget resource entirely (modules/platform/monitoring.tf
# gates it on amount > 0 AND a billing account).
#
# Deliberate: google_billing_budget lives on the BILLING ACCOUNT, not the
# project, so Terraform cannot grant the deployer access to it the way it
# grants everything else here — it would need roles/billing.costsManager
# added by hand at the billing-account level, outside this repo's blast
# radius. Every apply would then 403 refreshing the budget.
#
# To enable it later: set an amount, uncomment billing_account, and grant
#   gcloud billing accounts add-iam-policy-binding <ACCOUNT_ID> \
#     --member=serviceAccount:sa-owc-dpar-p-deploy-1@owc-dpar-p.iam.gserviceaccount.com \
#     --role=roles/billing.costsManager
billing_budget_amount = 0
# billing_account     = "0X0X0X-0X0X0X-0X0X0X"
