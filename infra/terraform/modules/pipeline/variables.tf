# ---------------------------------------------------------------------------
# The reusable pipeline module.
#
# A pipeline declares its schedules, resource sizing, secrets, state volume,
# and alert thresholds. Adding a third pipeline is one module block plus a
# tfvars entry — not new infrastructure code. This module is instantiated
# twice today (lightcast and enrollment) and those two are about as different
# as two pipelines get: one is a credentialed warehouse extract fanned across
# 41 parallel tasks, the other a single-task stateful scraper with a mounted
# filesystem.
# ---------------------------------------------------------------------------

variable "name" {
  type        = string
  description = "Pipeline name. Must match the `owcdata run <name>` argument and the `pipeline` column in owc_ops.pipeline_runs."
}

variable "project_id" { type = string }
variable "env" { type = string }

variable "region" {
  type        = string
  description = "Cloud Run and Cloud Scheduler region."
  default     = "us-central1"
}

variable "image" {
  type        = string
  description = <<-EOT
    Container image, referenced BY DIGEST (…@sha256:…), not by tag.

    A digest makes a rollback a git revert. A tag makes it a race against
    whatever is currently pushed under that tag.
  EOT
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest (repo@sha256:...), not by tag, so rollback is a revert."
  }
}

variable "service_account_email" {
  type        = string
  description = "Runtime identity for this pipeline's job. One per pipeline."
}

variable "scheduler_service_account_email" {
  type        = string
  description = "Identity Cloud Scheduler uses. Gets run.invoker on THIS job only."
}

# -- schedules ---------------------------------------------------------------
variable "schedules" {
  type = list(object({
    name       = string
    cron       = string
    args       = list(string)
    task_count = optional(number, 1)
  }))
  description = <<-EOT
    One Cloud Scheduler job per entry. `args` and `task_count` are sent as a
    run-time override, so all of a pipeline's groups share one Cloud Run Job
    definition and differ only in what the scheduler asks for.
  EOT
}

variable "timezone" {
  type    = string
  default = "America/Chicago"
}

# -- Cloud Run sizing --------------------------------------------------------
variable "task_timeout" {
  type        = string
  description = <<-EOT
    Per-task timeout.

    **The default is 10 minutes** and would silently kill the large Lightcast
    queries. This must be set explicitly for every pipeline.
  EOT
}

variable "max_retries" {
  type        = number
  description = "Task retries. Covers transient network and Snowflake faults."
  default     = 3
}

variable "parallelism" {
  type        = number
  description = <<-EOT
    Concurrent tasks.

    For lightcast the ceiling is Snowflake, not Cloud Run:
    MAX_CONCURRENCY_LEVEL defaults to 8 statements per warehouse cluster, so
    fanning past ~8 just queues while Cloud Run bills for blocked tasks. More
    importantly, **reader-account warehouse credits bill to Lightcast**, and
    jumping from one query at a time to 8 is an 8x concurrency increase on
    someone else's bill that could trip a provider-side resource monitor.

    Talk to Lightcast before raising this above 4.
  EOT
  default     = 1
}

variable "cpu" {
  type        = string
  description = "vCPU per task. Coupled to memory: 1 vCPU allows 512 MiB–4 GiB."
  default     = "1"
}

variable "memory" {
  type        = string
  description = <<-EOT
    Memory per task.

    Memory and CPU are COUPLED — asking for 32 GiB would force 8 vCPU nobody
    needs. 2 GiB is right here because the Parquet writer streams: measured
    peak is ~290 MB regardless of result-set size.

    Note Cloud Run's filesystem is in-memory in BOTH execution generations
    with no size limit, so anything written to local disk counts against this.
  EOT
  default     = "2Gi"
}

variable "task_count_default" {
  type        = number
  description = "Task count on the job definition. Schedulers override it per group."
  default     = 1
}

# -- environment and secrets -------------------------------------------------
variable "env_vars" {
  type        = map(string)
  description = "Plain environment variables for the container."
  default     = {}
}

variable "secret_env_vars" {
  type = map(object({
    secret_id = string
    version   = optional(string, "latest")
  }))
  description = <<-EOT
    Secret Manager values exposed as env vars. Empty for a pipeline with no
    secrets — the enrollment scraper reads a public webpage and is granted no
    secret access at all.
  EOT
  default     = {}
}

# -- state volume ------------------------------------------------------------
variable "state_volume" {
  type = object({
    bucket     = string
    mount_path = string
    read_only  = optional(bool, false)
  })
  description = <<-EOT
    Optional GCS bucket mounted with FUSE, for a pipeline that keeps state.

    This is what preserves the enrollment scraper's download cache across
    ephemeral containers: mounting the bucket at its `data/` path makes
    os.path.exists() work unchanged, so the short-circuit-when-nothing-is-new
    logic survives with essentially no code change. Without it the scraper
    would re-download Oklahoma's entire back catalogue every month.

    Requires execution environment gen2 (set below). The mount must complete
    within 30 seconds or the job fails.
  EOT
  default     = null
}

# -- alerts ------------------------------------------------------------------
variable "notification_channels" {
  type        = list(string)
  description = "Shared channel set from the platform module."
  default     = []
}

variable "event_alerts" {
  type = list(object({
    key          = string
    event        = string
    title        = string
    description  = string
    extra_filter = optional(string, "")
  }))
  description = <<-EOT
    Log-based alerts on this pipeline's structured-log events.

    `event` must match a `jsonPayload.event` string emitted by the code —
    they come from the classes in src/owcdata/errors.py and from
    core/quality.py. A typo'd event applies cleanly and then never fires,
    which is worse than no alert, so tests/unit/test_exit_codes.py pins the
    exact strings.
  EOT
  default     = []
}

variable "memory_utilization_threshold" {
  type        = number
  description = "Alert above this fraction of the memory limit. Early warning before an OOM kill."
  default     = 0.85
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "metric_propagation_wait" {
  type        = string
  description = <<-EOT
    How long to wait after creating log-based metrics before creating the
    alert policies that reference them.

    A log-based metric is visible to the Logging API immediately but takes
    time to appear as a Monitoring metric descriptor. Until it does, creating
    an alert policy against it fails with
    "Cannot find metric(s) that match type = ... If a metric was created
    recently, it could take up to 10 minutes to become available."

    depends_on does not help: the metric genuinely exists, it is just not
    queryable yet. Only elapsed time fixes it.

    This waits on create only, so it costs nothing on subsequent applies. The
    API's stated worst case is 10 minutes; in practice descriptors appear
    within about a minute. If an apply still races, re-running it is safe and
    completes — Terraform is idempotent here.
  EOT
  default     = "90s"
}

variable "name_prefix" {
  type        = string
  description = "Project prefix for the OMES naming convention. See modules/platform/naming.tf."
}

variable "schedulers_paused" {
  type        = bool
  description = <<-EOT
    Create the Cloud Scheduler jobs but leave them PAUSED. True in dev.

    Both environments read the same pipelines.yml, so without this dev fires
    the identical schedule prod does — 41 Snowflake queries at 06:00 on the
    1st, at the same minute as prod, every month. Those credits bill to
    LIGHTCAST, and the two environments would also contend for
    TULSA_FOR_YOU_WH. Dev exists to prove a deploy works; the smoke run in
    the deploy workflow does that, and nobody reads dev's marts.

    Paused rather than absent on purpose. Terraform still manages the job, so
    the oauth_token wiring and the run.invoker grant are exercised and
    drift-detected in dev instead of being first tried in prod. Resuming one
    to test it is a single command and needs no Terraform change:

      gcloud scheduler jobs resume <name> --location <region>

    Note that a resume done by hand is NOT reverted by a later apply only if
    you also flip this variable; otherwise the next apply pauses it again.
  EOT
  default     = false
}
