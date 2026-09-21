# prod
project_id        = "owc-data-prod"
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

billing_budget_amount = 500
# billing_account     = "0X0X0X-0X0X0X-0X0X0X"
