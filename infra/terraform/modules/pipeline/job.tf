resource "google_cloud_run_v2_job" "this" {
  name     = local.job_name
  project  = var.project_id
  location = var.region
  labels   = var.labels

  deletion_protection = false

  template {
    # Task retries live on the execution template, alongside parallelism.
    parallelism = var.parallelism
    task_count  = var.task_count_default

    template {
      service_account = var.service_account_email

      # EXPLICIT, not defaulted: Cloud Run's default task timeout is 10
      # minutes and would silently kill the large Lightcast queries.
      timeout     = var.task_timeout
      max_retries = var.max_retries

      # gen2 is required for GCS volume mounts. Note it does NOT change the
      # fact that the filesystem is in-memory — that is true in both
      # generations, with no size limit, so writing past the memory
      # allocation crashes the instance rather than filling a disk.
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

      containers {
        image = var.image
        args  = ["run", var.name]

        resources {
          limits = {
            cpu    = var.cpu
            memory = var.memory
          }
        }

        dynamic "env" {
          for_each = var.env_vars
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = var.secret_env_vars
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value.secret_id
                version = env.value.version
              }
            }
          }
        }

        dynamic "volume_mounts" {
          for_each = var.state_volume == null ? [] : [var.state_volume]
          content {
            name       = "state"
            mount_path = volume_mounts.value.mount_path
          }
        }
      }

      dynamic "volumes" {
        for_each = var.state_volume == null ? [] : [var.state_volume]
        content {
          name = "state"
          gcs {
            bucket    = volumes.value.bucket
            read_only = volumes.value.read_only
          }
        }
      }
    }
  }

  lifecycle {
    # The deploy workflow updates the image digest; nothing else about the job
    # should change outside Terraform.
    ignore_changes = [
      template[0].template[0].containers[0].image,
    ]
  }
}

# run.developer on THIS job only, not project-wide.
#
# NOT run.invoker, which is the intuitive choice and is wrong here.
# scheduler.tf posts an `overrides` body, and running a job WITH OVERRIDES
# requires run.jobs.runWithOverrides. roles/run.invoker grants exactly
# run.instances.invoke, run.jobs.run and run.routes.invoke — so every
# scheduled fire returns 403 while the binding reads as perfectly correct,
# because it IS correct for a plain run. Confirmed on owc-dpar-d:
# `gcloud iam roles describe roles/run.invoker` is the one-command check.
#
# A manual `gcloud run jobs execute` does not catch this. It runs as the
# operator, who holds run.developer project-wide, so the job works by hand
# and fails on every schedule. Prove the scheduler separately — see
# docs/deploy.md#prove-the-scheduler.
#
# The tighter alternative is a custom role holding only run.jobs.run and
# run.jobs.runWithOverrides. This repo has a no-custom-roles principle
# (modules/platform/iam.tf), so that is a deliberate reversal to reach for
# only if an org objects to run.developer scoped to a single job.
#
# Skipped entirely when the deploy identity cannot write a job's IAM policy
# (run.developer rather than run.admin). An admin then grants the same thing
# by hand — `make scheduler-grant` prints the commands.
resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  count = var.scheduler_job_iam_in_terraform ? 1 : 0

  name     = google_cloud_run_v2_job.this.name
  project  = var.project_id
  location = var.region
  role     = "roles/run.developer"
  member   = "serviceAccount:${var.scheduler_service_account_email}"
}
