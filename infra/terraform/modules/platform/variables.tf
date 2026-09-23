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
    Region or multi-region for GCS and all three BigQuery datasets.

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

variable "name_prefix" {
  type        = string
  description = <<-EOT
    The project prefix that every resource name is built around, following the
    OMES convention `<type>-<project-prefix>-<qualifier>-<seq>` — so
    `owc-dpar-d` yields `gcs-owc-dpar-d-raw-1`. Normally the project id.

    Kept separate from `env` on purpose. `env` stays `dev`/`prod` because it
    namespaces the log-based metrics and prints in alert titles, where `d`
    would read badly and a change would orphan the existing metrics. This
    variable only ever affects resource names.
  EOT

  validation {
    # Service account account_id is capped at 30 characters, and the longest
    # one here is `sa-<prefix>-enrollment-1` — 16 characters of fixed parts.
    # Failing at plan time with this sentence beats a 400 from the IAM API
    # partway through an apply.
    condition     = length(var.name_prefix) <= 14
    error_message = "name_prefix must be 14 characters or fewer: it is embedded in service account ids, which GCP caps at 30, and 'sa-<prefix>-enrollment-1' already spends 16."
  }

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits and hyphens, starting with a letter and not ending in a hyphen."
  }
}

variable "freshness_check_enabled" {
  type        = bool
  description = <<-EOT
    Run the scheduled freshness query and its "a pipeline did not run" alert.
    False in dev, and it must track `schedulers_paused` on the pipelines.

    Freshness asks "has this pipeline run inside its interval plus grace?".
    With dev's schedulers paused the honest answer is no, forever — dev only
    runs when someone deploys — so the alert would fire on a person's inbox
    every month for working-as-intended. That is how a team learns to ignore
    an alert channel, and it is the same channel prod uses.
  EOT
  default     = true
}

variable "secret_replica_locations" {
  type        = list(string)
  description = <<-EOT
    Regions to replicate the Snowflake secret into. Empty means `[var.region]`.

    Exists because `replication { auto {} }` puts a secret in `global`, and an
    organization with `constraints/gcp.resourceLocations` rejects that:

      Error 400: Constraint constraints/gcp.resourceLocations violated
      attempting to create a secret in [global]

    Naming regions explicitly satisfies the policy. One replica is enough —
    the only reader is a Cloud Run job in `region` — but add a second if your
    policy permits it and you want the redundancy.

    Replication is fixed at creation. Changing this on an existing secret
    forces replacement, which destroys its versions, so the module ignores
    changes to it. To actually move a secret, delete and recreate it and
    store the password again.
  EOT
  default     = []
}
