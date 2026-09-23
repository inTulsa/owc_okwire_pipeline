variable "project_id" {
  type        = string
  description = "GCP project for this environment."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "location" {
  type        = string
  description = "GCS + BigQuery location. Must be the same for both or load jobs fail."
  default     = "US"
}

variable "image_digest" {
  type        = string
  description = <<-EOT
    Full image reference pinned by digest, e.g.
    us-central1-docker.pkg.dev/PROJECT/ar-<name_prefix>-images-1/owcdata@sha256:abc...

    Required, with no default, on purpose: the pipeline module refuses a tag,
    and a forgotten image is better as a plan error than as a job that cannot
    pull at 06:00. Build one first with `make build ENV=dev`; CI passes the
    digest it just built.
  EOT
}

variable "alert_emails" {
  type        = list(string)
  description = "Distribution list, not individuals."
  default     = []
}

variable "billing_account" {
  type    = string
  default = ""
}

variable "billing_budget_amount" {
  type    = number
  default = 0
}

variable "snowflake_account" {
  type    = string
  default = "EMSIBG-READER_TULSA_FOR_YOU"
}

variable "snowflake_user" {
  type        = string
  description = "Snowflake login. Not a secret; the password is in Secret Manager."

  # No default, and the placeholder is rejected. This value is only ever
  # used at RUNTIME, as an env var on the lightcast job, so a wrong one
  # applies perfectly cleanly and then fails on the 1st of the month at
  # 06:00, unattended, with a Snowflake auth error. In prod that is a month
  # after the mistake was made. Failing the plan costs a second instead.
  validation {
    condition     = length(trimspace(var.snowflake_user)) > 0 && !can(regex("REPLACE_ME", var.snowflake_user))
    error_message = "snowflake_user must be this environment's real Snowflake login — the tfvars ship with a REPLACE_ME placeholder. It is not a secret; the password goes to Secret Manager separately."
  }
}

variable "name_prefix" {
  type        = string
  description = <<-EOT
    The project prefix every resource name is built around, following the OMES
    convention `<type>-<project-prefix>-<qualifier>-<seq>` — so `owc-dpar-d`
    yields `gcs-owc-dpar-d-raw-1`.

    Supplied by the Makefile, which defaults it to `project_id`. It is a
    separate variable because the two are allowed to diverge: a project id
    longer than 14 characters still needs a prefix short enough for a service
    account id. Override with `make <target> NAME_PREFIX=...`.
  EOT
}
