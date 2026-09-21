# dev
project_id        = "owc-data-dev"
region            = "us-central1"
location          = "US"
github_repository = "tulsateam/owc_okwire_pipeline"

# Dev accepts any ref so a branch can be tested. Prod pins refs/heads/main.
allowed_refs = []

# A distribution list, so people join and leave without a Terraform change.
alert_emails = ["owc-data-alerts@tulsaforyou.com"]

snowflake_user = "REPLACE_ME@tulsaforyou.com"

# Required. Build first: `make build ENV=dev`, then pass the digest it prints.
# CI supplies this with -var; it has no default on purpose.
# image_digest = "us-central1-docker.pkg.dev/owc-data-dev/okw-images/owcdata@sha256:..."

billing_budget_amount = 100
# billing_account     = "0X0X0X-0X0X0X-0X0X0X"
