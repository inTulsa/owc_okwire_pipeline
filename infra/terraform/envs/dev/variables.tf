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

variable "github_repository" {
  type        = string
  description = "owner/repo allowed to deploy via WIF."
}

variable "allowed_refs" {
  type        = list(string)
  description = "Refs allowed to deploy. Dev accepts any; prod should pin refs/heads/main."
  default     = []
}

variable "state_bucket" {
  type        = string
  description = <<-EOT
    The GCS bucket holding this environment's Terraform state, which the
    deployer is granted objectAdmin on.

    Deliberately has NO default. Bucket names are globally unique, so a
    shared default silently puts every environment's state in whichever
    project bootstrapped first — and `bootstrap.sh` cannot detect it,
    because `describe` succeeds for a bucket you can read in another
    project. Prod state living in the dev project inverts the trust
    relationship: dev is where people feel free to break things.

    One bucket per environment, in that environment's own project. The
    literal must also be set in backend.tf, which cannot read a variable.
  EOT
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
  default     = ""
}

variable "name_prefix" {
  type        = string
  description = <<-EOT
    Project prefix for the OMES resource naming convention
    `<type>-<project-prefix>-<qualifier>-<seq>`, so `owc-dpar-d` produces
    `gcs-owc-dpar-d-raw-1`. Normally identical to project_id.

    Separate from project_id because they are allowed to diverge: a sandbox
    project with a long id still needs a prefix short enough for a service
    account id. Capped at 14 characters — see modules/platform/variables.tf.
  EOT
}
