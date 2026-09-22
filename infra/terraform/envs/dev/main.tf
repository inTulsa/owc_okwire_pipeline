# ---------------------------------------------------------------------------
# dev environment.
#
# Read pipelines.yml and sql/owc/ directly, so the schedules and task counts
# in GCP are derived from the same files the Python reads. A schedule cannot
# drift between the repo and the deployed scheduler, and adding a .sql file
# changes the task count on the next apply with no config edit.
# ---------------------------------------------------------------------------
locals {
  repo_root = "${path.module}/../../../.."

  pipelines  = yamldecode(file("${local.repo_root}/pipelines.yml"))
  lightcast  = local.pipelines.lightcast
  enrollment = local.pipelines.enrollment

  # Every .sql file on disk, by stem. This IS the dataset list.
  sql_datasets = sort([
    for f in fileset("${local.repo_root}/${local.lightcast.source_dir}", "*.sql") :
    trimsuffix(f, ".sql")
  ])

  default_group = local.lightcast.defaults.group

  # Datasets explicitly claimed by a non-default group.
  claimed_datasets = flatten([
    for name, cfg in local.lightcast.groups : lookup(cfg, "datasets", [])
  ])

  # The default group gets everything nobody else claimed, which is what
  # preserves the original pipeline's glob-the-directory behavior.
  group_datasets = {
    for name, cfg in local.lightcast.groups : name => (
      name == local.default_group
      ? [for d in local.sql_datasets : d if !contains(local.claimed_datasets, d)]
      : lookup(cfg, "datasets", [])
    )
  }

  # One task per dataset. A group with no datasets gets no scheduler at all —
  # filling in the quarterly/yearly lists in pipelines.yml is what creates
  # those schedulers.
  lightcast_schedules = [
    for name, cfg in local.lightcast.groups : {
      name       = name
      cron       = cfg.schedule
      args       = ["--group", name]
      task_count = length(local.group_datasets[name])
    }
    if length(local.group_datasets[name]) > 0
  ]

  labels = {
    managed_by = "terraform"
    system     = "owc-data-platform"
    env        = var.env_name
  }

  common_env = {
    OWC_ENV                = var.env_name
    OWC_TARGET             = "gcs"
    OWC_GCP_PROJECT        = var.project_id
    OWC_GCS_RAW_BUCKET     = module.platform.raw_bucket
    OWC_BQ_STAGING_DATASET = module.platform.datasets.staging
    OWC_BQ_MARTS_DATASET   = module.platform.datasets.marts
    OWC_BQ_OPS_DATASET     = module.platform.datasets.ops
    OWC_BQ_LOCATION        = var.location
    OWC_LOG_LEVEL          = "INFO"
  }
}

variable "env_name" {
  type    = string
  default = "dev"
}

# ---------------------------------------------------------------------------
# Shared platform
# ---------------------------------------------------------------------------
module "platform" {
  source = "../../modules/platform"

  project_id      = var.project_id
  env             = var.env_name
  name_prefix     = var.name_prefix
  region          = var.region
  location        = var.location
  alert_emails    = var.alert_emails
  labels          = local.labels
  billing_account = var.billing_account

  billing_budget_amount = var.billing_budget_amount

  # Dev only: lets `terraform destroy` clean up a scratch environment. Never
  # true in prod.
  raw_bucket_force_destroy = true

  # Off in dev: with schedulers paused nothing runs on a cadence, so this
  # would alert every month for working-as-intended — on the same channel
  # prod uses.
  freshness_check_enabled = false

  freshness_thresholds = concat(
    [
      for name, cfg in local.lightcast.groups : {
        pipeline   = "lightcast"
        group_name = name
        # Max interval for the cadence plus this group's configured grace.
        max_age_hours = (
          name == "yearly" ? 8784 : name == "quarterly" ? 2208 : 744
        ) + lookup(cfg, "freshness_grace_hours", 48)
      }
    ],
    [{
      pipeline      = "enrollment"
      group_name    = "monthly"
      max_age_hours = 744 + lookup(local.enrollment, "freshness_grace_hours", 72)
    }]
  )
}

# ---------------------------------------------------------------------------
# lightcast: one task per dataset, parallelism 4, three possible schedules.
# ---------------------------------------------------------------------------
module "lightcast" {
  source = "../../modules/pipeline"

  name        = "lightcast"
  project_id  = var.project_id
  env         = var.env_name
  name_prefix = var.name_prefix
  region      = var.region
  image       = var.image_digest
  labels      = local.labels

  service_account_email           = module.platform.service_account_emails.lightcast
  scheduler_service_account_email = module.platform.service_account_emails.scheduler

  # Dev must NOT run prod's schedule. Both environments read the same
  # pipelines.yml, so without this dev fires the same 41 Snowflake queries at
  # the same minute as prod every month, and those credits bill to Lightcast.
  # The jobs are still created, so their wiring is exercised here rather than
  # first tried in prod — they just never fire on their own.
  schedulers_paused = true

  schedules          = local.lightcast_schedules
  task_count_default = length(local.sql_datasets)

  # 2h, not the 10-minute default, which would silently kill the large queries.
  task_timeout = "7200s"
  max_retries  = 3

  # Snowflake-bound, and the credits bill to Lightcast. Talk to them before
  # raising this. See the module variable's documentation.
  parallelism = 4

  cpu    = "1"
  memory = "2Gi"

  env_vars = merge(local.common_env, {
    SNOWFLAKE_ACCOUNT   = var.snowflake_account
    SNOWFLAKE_USER      = var.snowflake_user
    SNOWFLAKE_WAREHOUSE = "TULSA_FOR_YOU_WH"
    SNOWFLAKE_DATABASE  = "LIGHTCAST"
    SNOWFLAKE_SCHEMA    = "TULSA_FOR_YOU"
  })

  secret_env_vars = {
    SNOWFLAKE_PASSWORD = {
      secret_id = module.platform.snowflake_secret_id
      version   = "latest"
    }
  }

  notification_channels = module.platform.notification_channels

  event_alerts = [
    {
      key         = "alert-4-quality"
      event       = "quality_check_failed"
      title       = "ALERT 4: lightcast quality check failed (publish blocked)"
      description = <<-EOT
        A quality check failed, so the publish was blocked and `owc_marts`
        still holds the last known-good data. The suspect rows are in
        `owc_staging` on purpose — query them and diff against the previous
        run before doing anything else.
      EOT
    },
    {
      key   = "alert-5-drift"
      event = "quality_check_failed"
      title = "ALERT 5: lightcast row count or max(YEAR) drifted"
      # Narrowed to the two drift checks specifically — this is the smoke
      # detector for the accepted risk that hardcoded year literals go stale.
      extra_filter = "(jsonPayload.check=\"row_count_drift\" OR jsonPayload.check=\"max_year_regressed\")"
      description  = <<-EOT
        A dataset's row count moved more than the configured percentage, or
        its `max(YEAR)` went backwards, compared with the previous successful
        run.

        **This is the alert for the known stale-year-literal risk.**
        `fact_regional_indicators.sql` pins `YEAR = 2025/2024/2023` and the
        `*_idx` files pin a 2015 baseline. On a schedule those eventually
        produce wrong-but-plausible numbers, which nothing else here would
        notice. It is a smoke detector, not a fix — the fix is editing the SQL.
      EOT
    },
    {
      key         = "alert-extract-failed"
      event       = "extract_failed"
      title       = "ALERT 1b: lightcast extract failed"
      description = "A Snowflake query or connection failed. Check the query id on the run manifest against Snowflake's query history."
    },
  ]
}

# ---------------------------------------------------------------------------
# enrollment: the proof the module generalizes.
#
# Same module, but single-task, short timeout, a FUSE-mounted state bucket,
# no secret access at all, and a completely different alert set.
# ---------------------------------------------------------------------------
module "enrollment" {
  source = "../../modules/pipeline"

  name        = "enrollment"
  project_id  = var.project_id
  env         = var.env_name
  name_prefix = var.name_prefix
  region      = var.region
  image       = var.image_digest
  labels      = local.labels

  service_account_email           = module.platform.service_account_emails.enrollment
  scheduler_service_account_email = module.platform.service_account_emails.scheduler

  # Dev must NOT run prod's schedule. Both environments read the same
  # pipelines.yml, so without this dev fires the same 41 Snowflake queries at
  # the same minute as prod every month, and those credits bill to Lightcast.
  # The jobs are still created, so their wiring is exercised here rather than
  # first tried in prod — they just never fire on their own.
  schedulers_paused = true

  schedules = [{
    name       = "monthly"
    cron       = local.enrollment.schedule
    args       = []
    task_count = 1
  }]

  task_timeout       = "1800s" # 30m
  max_retries        = 3
  parallelism        = 1 # inherently sequential
  task_count_default = 1
  cpu                = "1"
  memory             = "2Gi"

  # The cache the scraper short-circuits on. Mounted at the path the script
  # already uses, so os.path.exists() works unchanged.
  state_volume = {
    bucket     = module.platform.enrollment_state_bucket
    mount_path = "/app/data"
  }

  env_vars = merge(local.common_env, {
    OWC_ENROLLMENT_DATA_DIR = "/app/data"
  })

  # Deliberately empty. The source is a public webpage; this job is granted no
  # secret access whatsoever.
  secret_env_vars = {}

  notification_channels = module.platform.notification_channels

  event_alerts = [
    {
      key         = "alert-6-no-files"
      event       = "no_source_files_found"
      title       = "ALERT 6: enrollment scrape found NOTHING on the page"
      description = <<-EOT
        Discovery matched zero files. **This is what Oklahoma redesigning
        their webpage looks like**, and it is the most likely failure this
        pipeline will ever have.

        Start from the page snapshot for this run at
        `gs://<raw-bucket>/enrollment/page_snapshots/<run_id>.html` and diff it
        against the previous run's. That turns the investigation into a diff
        instead of re-reading 759 lines of selectors.

        The original script printed "Nothing to do." and exited 0 here.
      EOT
    },
    {
      key         = "alert-7-reshape-skipped"
      event       = "workbook_reshape_skipped"
      title       = "ALERT 7: enrollment workbook was skipped"
      description = <<-EOT
        A workbook was discovered but failed to reshape, so its fiscal year is
        missing from the merged output. This path was previously invisible —
        the script printed `[skip]` and carried on.

        The raw workbook is archived at
        `gs://<raw-bucket>/enrollment/source_files/` — open it and compare its
        sheet and header layout against the conventions in `scrape.py`.
      EOT
    },
    {
      key         = "alert-6b-page-structure-drifted"
      event       = "grid_wrapper_not_found"
      title       = "ALERT 6b: enrollment page structure changed (fallback still worked)"
      description = <<-EOT
        The scraper could not find Oklahoma's `aem-Grid` wrapper and fell back
        to searching the whole page. **This run still succeeded** — the links
        were found anyway — so nothing is broken yet.

        This is the early warning before [alert 6](#alert-6-no-files). The
        page has been restructured, the selectors in `scrape.py` are drifting
        out of date, and the next change is likely to break discovery
        outright. Fix it on your schedule rather than Oklahoma's.

        Diff this run's page snapshot against the previous one:
        `gs://<raw-bucket>/enrollment/page_snapshots/<run_id>.html`. Then save
        the new HTML over `tests/fixtures/enrollment/page.html` and run
        `make test` — the failing assertions tell you exactly which selector
        moved.
      EOT
    },
    {
      key         = "alert-7b-unreadable"
      event       = "no_matching_sheet"
      title       = "ALERT 7b: enrollment workbook has no recognizable sheet"
      description = "A downloaded workbook's sheet layout matches none of the known signatures. Same class of failure as a page redesign, one level down."
    },
    {
      key         = "alert-4-quality-enrollment"
      event       = "quality_check_failed"
      title       = "ALERT 4: enrollment quality check failed (publish blocked)"
      description = "A quality check failed on the merged enrollment table. Staging is left in place to diff."
    },
  ]
}

# ---------------------------------------------------------------------------
# Keyless deploys
# ---------------------------------------------------------------------------
module "wif" {
  source = "../../modules/wif"

  project_id        = var.project_id
  env               = var.env_name
  name_prefix       = var.name_prefix
  github_repository = var.github_repository
  allowed_refs      = var.allowed_refs
  state_bucket      = var.state_bucket

  artifact_registry_repository_id = module.platform.image_repository_id
  artifact_registry_location      = var.region

  # Every identity this repo ATTACHES to a resource. Setting a service
  # account on something requires iam.serviceAccounts.actAs on it, so an
  # identity missing here is a CI-only 403 — a human applying as project
  # owner already has actAs on everything and never sees it.
  #
  # The list must stay in step with these three places, and nothing enforces
  # that but `make deployer-check`:
  #   modules/pipeline/job.tf        service_account        (lightcast, enrollment)
  #   modules/pipeline/scheduler.tf  service_account_email  (scheduler)
  #   modules/platform/monitoring.tf service_account_name   (freshness)
  # plus the build identity, which `gcloud builds submit` runs as.
  impersonatable_service_accounts = [
    module.platform.service_account_emails.lightcast,
    module.platform.service_account_emails.enrollment,
    # Setting oauth_token.service_account_email on a Cloud Scheduler job
    # needs actAs on it, exactly as setting a Cloud Run job's does.
    module.platform.service_account_emails.scheduler,
    # The freshness scheduled query runs as this. Only created when
    # freshness_check_enabled is true — so dev, which disables it, cannot
    # surface a missing grant here and PROD is the first place it would.
    module.platform.service_account_emails.freshness,
    # Submitting a build requires actAs on the identity the build runs as.
    module.platform.service_account_emails.build,
  ]
}
