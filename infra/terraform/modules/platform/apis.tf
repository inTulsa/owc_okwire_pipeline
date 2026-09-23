# APIs are enabled once, by infra/gcloud/01-admin-identities.sh.
#
# google_project_service used to own them, which meant the Terraform
# principal needed roles/serviceusage.serviceUsageAdmin on every run —
# including runs that changed nothing, because refresh reads each one. The
# list now lives in infra/gcloud/names.sh (REQUIRED_APIS), and
# `make iam-check` verifies all 16 are on before an apply.
#
# This file is deliberately not empty: it is the first place someone looks
# for "where are the APIs enabled?".
