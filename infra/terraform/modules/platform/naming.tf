# ---------------------------------------------------------------------------
# Resource naming — OMES convention.
#
#   <type>-<project-prefix>-<qualifier>-<seq>
#
# Taken from the Phase Two infrastructure architecture drawing (OMES Data
# Communications Group, Legacy Spoke Reference Architecture, rev 1.1.0), which
# names `vpc-owc-dpar-d-1` and `sn-owc-dpar-d-pri-1`.
#
# ONLY those two abbreviations are fixed by the drawing, and both belong to
# the network layer that OMES provisions from omes-net-gcp-tf-owc-dpar-<env>.
# Every abbreviation in `abbrev` below is therefore an inference from that
# shape, not something the drawing states. They are collected here, rather
# than interpolated at each resource, so correcting one is a single edit that
# renames consistently everywhere it is used.
#
# >> OMES: confirm these against your standard before the first apply. <<
#
# BigQuery is deliberately NOT in this scheme. Dataset ids cannot contain
# hyphens, PowerBI connects to `owc_marts` by name, and the three dataset
# names appear in 84 places across the Python and the docs. They are also
# already scoped to one project per environment, so repeating the project in
# the name buys nothing. See bigquery.tf.
# ---------------------------------------------------------------------------
locals {
  abbrev = {
    bucket   = "gcs"
    sa       = "sa"
    secret   = "sm"
    registry = "ar"
  }

  name = {
    # Buckets. Global namespace, 3-63 chars.
    raw_bucket              = "${local.abbrev.bucket}-${var.name_prefix}-raw-1"
    enrollment_state_bucket = "${local.abbrev.bucket}-${var.name_prefix}-enrollment-state-1"

    # Service accounts. account_id is capped at 30 characters, which is the
    # binding constraint on name_prefix — see the validation on that variable.
    sa_lightcast  = "${local.abbrev.sa}-${var.name_prefix}-lightcast-1"
    sa_enrollment = "${local.abbrev.sa}-${var.name_prefix}-enrollment-1"
    sa_scheduler  = "${local.abbrev.sa}-${var.name_prefix}-scheduler-1"
    sa_build      = "${local.abbrev.sa}-${var.name_prefix}-build-1"
    sa_powerbi    = "${local.abbrev.sa}-${var.name_prefix}-powerbi-1"
    sa_freshness  = "${local.abbrev.sa}-${var.name_prefix}-freshness-1"

    secret_snowflake = "${local.abbrev.secret}-${var.name_prefix}-snowflake-password-1"
    registry_images  = "${local.abbrev.registry}-${var.name_prefix}-images-1"
  }
}

# ---------------------------------------------------------------------------
# Service account emails, derived rather than read off the resources.
#
# Every reference in this module goes through this map, so the module works
# identically whether it CREATES the accounts (manage_identities = true) or
# merely attaches ones that OMES created with
# infra/gcloud/01-admin-identities.sh (manage_identities = false).
#
# Derived from the naming convention rather than looked up with a
# `data "google_service_account"` block on purpose: the data source needs
# iam.serviceAccounts.get, which none of the resource-admin roles in
# TF_PRINCIPAL_ROLES carries. Adding a permission in order to discover a name
# this file already knows how to build would put an IAM read back into every
# plan — the exact thing this split removes. `make iam-check` confirms the
# accounts exist, using the operator's own gcloud credentials.
# ---------------------------------------------------------------------------
locals {
  sa_email = {
    lightcast  = "${local.name.sa_lightcast}@${var.project_id}.iam.gserviceaccount.com"
    enrollment = "${local.name.sa_enrollment}@${var.project_id}.iam.gserviceaccount.com"
    scheduler  = "${local.name.sa_scheduler}@${var.project_id}.iam.gserviceaccount.com"
    build      = "${local.name.sa_build}@${var.project_id}.iam.gserviceaccount.com"
    powerbi    = "${local.name.sa_powerbi}@${var.project_id}.iam.gserviceaccount.com"
    freshness  = "${local.name.sa_freshness}@${var.project_id}.iam.gserviceaccount.com"
  }
}
