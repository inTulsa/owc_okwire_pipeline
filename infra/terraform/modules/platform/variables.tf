variable "project_id" {
  type        = string
  description = "GCP project. One project per environment."
}

variable "env" {
  type        = string
  description = "dev | prod. Suffixes every resource name."
  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod."
  }
}

variable "region" {
  type        = string
  description = "Region for Cloud Run, Artifact Registry, and Cloud Scheduler."
  default     = "us-central1"
}

variable "location" {
  type        = string
  description = <<-EOT
    Region or multi-region for GCS and all four BigQuery datasets.

    Co-location is mandatory, not a preference: a load job from a bucket in
    one location into a dataset in another fails outright. This single
    variable feeds both so they cannot drift apart.
  EOT
  default     = "US"
}

variable "alert_emails" {
  type        = list(string)
  description = <<-EOT
    Where alerts go. Point this at a distribution list, not at individuals, so
    people can join and leave the on-call rotation without a Terraform change.
  EOT
  default     = []
}

variable "billing_budget_amount" {
  type        = number
  description = "Monthly budget in USD for the cost alert. 0 disables it."
  default     = 0
}

variable "billing_account" {
  type        = string
  description = "Billing account id, required only when billing_budget_amount > 0."
  default     = ""
}

variable "raw_bucket_force_destroy" {
  type        = bool
  description = <<-EOT
    Allow `terraform destroy` to delete a non-empty raw bucket. Never true in
    prod: the realistic disaster for a small team is a fat-fingered destroy,
    not a quota.
  EOT
  default     = false
}

variable "staging_table_expiration_days" {
  type        = number
  description = "Staging tables are diffing material after a failure, not a permanent store."
  default     = 7
}

variable "labels" {
  type        = map(string)
  description = "Applied to every resource that supports labels."
  default     = {}
}

variable "freshness_thresholds" {
  type = list(object({
    pipeline      = string
    group_name    = string
    max_age_hours = number
  }))
  description = <<-EOT
    How stale a schedule group is allowed to get before the freshness alert
    fires: the group's own interval plus its grace period.

    This exists because Cloud Monitoring's metric-absence condition caps at
    23.5 hours, which covers a daily job and nothing else. For monthly,
    quarterly, and yearly cadences a scheduled query over owc_ops.pipeline_runs
    is the ONLY thing that notices a scheduler which quietly stopped firing.

    Defaults are max-interval + grace:
      monthly   31d (744h) + 48h  =  792h
      quarterly 92d (2208h) + 96h = 2304h
      yearly   366d (8784h) + 168h = 8952h
      enrollment monthly 744h + 72h = 816h
  EOT
  default = [
    { pipeline = "lightcast", group_name = "monthly", max_age_hours = 792 },
    { pipeline = "lightcast", group_name = "quarterly", max_age_hours = 2304 },
    { pipeline = "lightcast", group_name = "yearly", max_age_hours = 8952 },
    { pipeline = "enrollment", group_name = "monthly", max_age_hours = 816 },
  ]
}

variable "freshness_check_schedule" {
  type        = string
  description = "How often the freshness query runs. Daily is plenty — it is checking month-scale staleness."
  default     = "every day 13:00"
}

variable "bigquery_scanned_bytes_threshold_gib" {
  type        = number
  description = "Alert when BigQuery scanned bytes exceed this in a day. Guards against a DirectQuery PowerBI report billing a scan per slicer click."
  default     = 500
}

variable "metric_propagation_wait" {
  type        = string
  description = "Wait after creating a log-based metric before an alert policy references it. See the pipeline module's variable of the same name."
  default     = "90s"
}
