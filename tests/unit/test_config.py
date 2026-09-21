"""Config loading and schedule-group assignment."""

from __future__ import annotations

import pytest

from owcdata.config import PipelinesConfig, Settings
from owcdata.errors import ConfigError


def test_repo_config_loads():
    config = PipelinesConfig.load()
    assert set(config.lightcast.groups) == {"monthly", "quarterly", "yearly"}
    assert config.lightcast.default_group == "monthly"
    assert config.enrollment.table == "enrollment_primary"


def test_every_sql_file_lands_in_exactly_one_group():
    """Adding a .sql file must need no config edit, and must not be run twice."""
    config = PipelinesConfig.load()
    lc = config.lightcast
    all_names = lc.all_datasets()
    assigned = [ds for g in lc.groups for ds in lc.datasets_in_group(g)]
    assert sorted(assigned) == sorted(all_names)
    assert len(assigned) == len(set(assigned)), "a dataset is assigned to two groups"


def test_unlisted_dataset_falls_into_the_default_group():
    config = PipelinesConfig.load()
    assert config.lightcast.group_for("a_brand_new_file") == "monthly"


def test_dataset_in_two_groups_is_rejected(tmp_path):
    p = tmp_path / "pipelines.yml"
    p.write_text(
        """
lightcast:
  source_dir: sql/owc
  defaults: {group: monthly}
  groups:
    monthly: {schedule: "0 6 1 * *", datasets: [fact_jobs]}
    yearly:  {schedule: "0 6 15 1 *", datasets: [fact_jobs]}
enrollment:
  schedule: "0 7 5 * *"
  page_url: https://example.test/x.html
"""
    )
    with pytest.raises(ConfigError, match="listed in both"):
        PipelinesConfig.load(p)


def test_default_group_must_exist(tmp_path):
    p = tmp_path / "pipelines.yml"
    p.write_text(
        """
lightcast:
  source_dir: sql/owc
  defaults: {group: weekly}
  groups:
    monthly: {schedule: "0 6 1 * *"}
enrollment:
  schedule: "0 7 5 * *"
  page_url: https://example.test/x.html
"""
    )
    with pytest.raises(ConfigError, match=r"defaults\.group"):
        PipelinesConfig.load(p)


def test_group_naming_a_nonexistent_sql_file_is_an_error(tmp_path):
    """A typo'd dataset name would otherwise silently never run."""
    p = tmp_path / "pipelines.yml"
    p.write_text(
        """
lightcast:
  source_dir: sql/owc
  defaults: {group: monthly}
  groups:
    monthly:  {schedule: "0 6 1 * *"}
    yearly:   {schedule: "0 6 15 1 *", datasets: [fact_jbos_typo]}
enrollment:
  schedule: "0 7 5 * *"
  page_url: https://example.test/x.html
"""
    )
    config = PipelinesConfig.load(p)
    with pytest.raises(ConfigError, match=r"no \.sql file"):
        config.lightcast.datasets_in_group("yearly")


def test_gcs_target_requires_project_and_bucket():
    with pytest.raises(Exception, match="OWC_GCP_PROJECT"):
        Settings(target="gcs", gcp_project="", gcs_raw_bucket="")
    ok = Settings(target="gcs", gcp_project="p", gcs_raw_bucket="b")
    assert ok.target == "gcs"


def test_local_enrollment_dir_is_not_the_production_mount_point():
    """A local run must not be able to write into the FUSE mount path."""
    assert str(Settings().enrollment_data_dir) != "data"
