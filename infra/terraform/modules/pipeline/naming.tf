# ---------------------------------------------------------------------------
# Resource naming — OMES convention. See modules/platform/naming.tf for the
# source of the pattern and the caveat about which abbreviations the
# architecture drawing actually fixes (only `vpc-` and `sn-`; the rest are
# inferred and are collected in these two files so they are cheap to correct).
#
#   <type>-<project-prefix>-<qualifier>-<seq>
# ---------------------------------------------------------------------------
locals {
  abbrev = {
    run_job   = "cr"
    scheduler = "cs"
  }

  # `var.name` is the pipeline: lightcast | enrollment.
  job_name = "${local.abbrev.run_job}-${var.name_prefix}-${var.name}-1"

  scheduler_name = {
    for s in var.schedules :
    s.name => "${local.abbrev.scheduler}-${var.name_prefix}-${var.name}-${s.name}-1"
  }
}
