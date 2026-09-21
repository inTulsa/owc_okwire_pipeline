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
    us-central1-docker.pkg.dev/PROJECT/okw-images/owcdata@sha256:abc...

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
  type    = string
  default = "okw-tfstate"
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
