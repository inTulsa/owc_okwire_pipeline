# ---------------------------------------------------------------------------
# Resource naming — OMES convention. See modules/platform/naming.tf for the
# pattern and the caveat on inferred abbreviations.
#
#   <type>-<project-prefix>-<qualifier>-<seq>
# ---------------------------------------------------------------------------
locals {
  abbrev = {
    sa       = "sa"
    wif_pool = "wip"
  }

  name = {
    # Workload identity pool ids are capped at 32 characters, deployer service
    # account ids at 30. name_prefix's own <=14 validation in the platform
    # module keeps both inside their limits.
    wif_pool    = "${local.abbrev.wif_pool}-${var.name_prefix}-github-1"
    sa_deployer = "${local.abbrev.sa}-${var.name_prefix}-deployer-1"
  }
}
