variable "project_id" { type = string }
variable "env" { type = string }

variable "github_repository" {
  type        = string
  description = <<-EOT
    The one repository allowed to mint tokens, as "owner/repo".

    This is not optional and not cosmetic. Without an attribute_condition
    restricting assertion.repository, **any GitHub repository on earth can
    mint tokens for this project** — it is the most common Workload Identity
    Federation misconfiguration and a full compromise. The validation below
    refuses an empty or wildcard value.
  EOT
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be exactly owner/repo — no wildcards, no empty value."
  }
}

variable "allowed_refs" {
  type        = list(string)
  description = <<-EOT
    Git refs allowed to assume the deployer, e.g. ["refs/heads/main"].

    Belt and braces on top of the repository condition: it stops a pull
    request from a fork, or a branch pushed by anyone with write access, from
    deploying. Empty means any ref in the named repository, which is
    acceptable for dev and not for prod.
  EOT
  default     = []
}

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket the deployer needs read/write on."
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Artifact Registry repo the deployer pushes images to."
}

variable "artifact_registry_location" { type = string }

variable "impersonatable_service_accounts" {
  type        = list(string)
  description = "Runtime SA emails the deployer may set on a Cloud Run job (iam.serviceAccountUser)."
  default     = []
}

variable "name_prefix" {
  type        = string
  description = "Project prefix for the OMES naming convention. See modules/platform/naming.tf."
}
