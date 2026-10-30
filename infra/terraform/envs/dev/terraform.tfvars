# dev  —  OMES project owc-dpar-d
#
# TESTING AGAINST YOUR OWN PROJECT
#
# Nothing in this file needs editing. Add PROJECT=your-project to every make
# command: it reaches the gcloud steps, the terraform -var values and the
# state bucket at init. See deploy.md, "Rehearsing against your own project".
#
# Use envs/dev, not envs/prod: prod sets schedulers_paused = false, so a test
# apply there creates LIVE schedulers that fire prod's monthly schedule at
# Lightcast's warehouse.
project_id = "owc-dpar-d"
region     = "us-central1"
location   = "US"

# A distribution list, so people join and leave without a Terraform change.
alert_emails = ["gurtaj.singh@workforce.ok.gov"]

snowflake_user = "analytics@tulsaforyou.com"

# Required. Build first: `make build ENV=dev`, then pass the digest it prints.
# CI supplies this with -var; it has no default on purpose.
# image_digest = "us-central1-docker.pkg.dev/owc-dpar-d/ar-owc-dpar-d-images-1/owcdata@sha256:..."

# Paused: dev runs when someone deploys or runs `make smoke`, not on a
# schedule. Both environments read the same pipelines.yml, so an unpaused dev
# fires the same 35 Snowflake queries as prod at the same minute and bills
# Lightcast twice. Unpause only briefly, to exercise the scheduled path.
schedulers_paused = true

billing_budget_amount = 0
# billing_account     = "0X0X0X-0X0X0X-0X0X0X"
