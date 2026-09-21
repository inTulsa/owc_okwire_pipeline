"""Configuration, validated at startup so a bad deploy fails before it bills.

Two sources, deliberately kept apart:

* ``Settings`` — the environment. Credentials, target, GCP resource names.
  Env vars only, so the same image runs on a laptop and on Cloud Run.
* ``PipelinesConfig`` — ``pipelines.yml``. Schedules, dataset groups, quality
  thresholds. Checked into git and also read by Terraform, so the schedule in
  the repo and the schedule in GCP cannot drift.
"""

from __future__ import annotations

import functools
import os
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from owcdata.errors import ConfigError

Target = Literal["local", "gcs"]

# Repo root: .../src/owcdata/config.py -> up three.
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PIPELINES_FILE = REPO_ROOT / "pipelines.yml"


# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
class SnowflakeSettings(BaseSettings):
    """The Lightcast reader account.

    Password auth is correct here and is not deprecated: Snowflake's password
    phase-out explicitly exempts reader accounts. The only change from the
    original pipeline is that the password arrives from Secret Manager rather
    than a .env file. See docs/01-architecture.md, ADR-004.
    """

    model_config = SettingsConfigDict(
        env_prefix="SNOWFLAKE_", env_file=".env", extra="ignore", case_sensitive=False
    )

    account: str = "EMSIBG-READER_TULSA_FOR_YOU"
    user: str = ""
    password: str = ""
    warehouse: str = "TULSA_FOR_YOU_WH"
    database: str = "LIGHTCAST"
    schema_: str = Field(default="TULSA_FOR_YOU", alias="SNOWFLAKE_SCHEMA")

    # Queued queries fail fast instead of sitting in the warehouse queue while
    # Cloud Run bills for a blocked task. MAX_CONCURRENCY_LEVEL defaults to 8
    # per cluster, so past ~8 concurrent statements everything just queues.
    statement_queued_timeout_seconds: int = 600
    # Per-statement ceiling. Below the Cloud Run task timeout on purpose, so a
    # runaway query surfaces as a Snowflake error rather than a killed task.
    statement_timeout_seconds: int = 6600

    def require_credentials(self) -> None:
        missing = [n for n in ("user", "password") if not getattr(self, n)]
        if missing:
            raise ConfigError(
                "Snowflake credentials missing: "
                + ", ".join(f"SNOWFLAKE_{m.upper()}" for m in missing)
            )


class Settings(BaseSettings):
    """Platform-level environment settings."""

    model_config = SettingsConfigDict(
        env_prefix="OWC_", env_file=".env", extra="ignore", case_sensitive=False
    )

    env: str = "dev"
    target: Target = "local"
    log_level: str = "INFO"

    # Identity of this run. Cloud Run injects the execution/task vars; locally
    # run_id is generated in cli.py.
    run_id: str = ""
    git_sha: str = "unknown"

    # GCP — required only when target == "gcs".
    gcp_project: str = ""
    gcs_raw_bucket: str = ""
    gcs_enrollment_state_bucket: str = ""
    bq_staging_dataset: str = "owc_staging"
    bq_marts_dataset: str = "owc_marts"
    bq_ops_dataset: str = "owc_ops"
    # Bucket and all three datasets must share this. Mixed regions make load
    # jobs fail outright rather than run slowly.
    bq_location: str = "US"

    # Local output roots. `--target local` reproduces the original pipelines'
    # on-disk behavior underneath these.
    local_output_dir: Path = Path("exports")
    # Deliberately NOT "data": a local run must not be able to write into the
    # directory the GCS-backed production cache is mounted at.
    enrollment_data_dir: Path = Path(".owcdata-local/enrollment/data")

    pipelines_file: Path = DEFAULT_PIPELINES_FILE

    @field_validator("target", mode="before")
    @classmethod
    def _lower_target(cls, v: Any) -> Any:
        return v.lower() if isinstance(v, str) else v

    @model_validator(mode="after")
    def _require_gcp_when_gcs(self) -> Settings:
        if self.target == "gcs":
            missing = [
                name for name in ("gcp_project", "gcs_raw_bucket") if not getattr(self, name)
            ]
            if missing:
                raise ValueError(
                    "target=gcs requires: " + ", ".join(f"OWC_{m.upper()}" for m in missing)
                )
        return self

    @property
    def is_cloud_run(self) -> bool:
        return bool(os.getenv("CLOUD_RUN_JOB"))

    @property
    def task_index(self) -> int:
        """Cloud Run's 0-based task index; 0 when running locally."""
        return int(os.getenv("CLOUD_RUN_TASK_INDEX", "0"))

    @property
    def task_count(self) -> int:
        return int(os.getenv("CLOUD_RUN_TASK_COUNT", "1"))


# ---------------------------------------------------------------------------
# pipelines.yml
# ---------------------------------------------------------------------------
class QualityConfig(BaseModel):
    row_count_drift_pct: float = 20.0
    known_row_counts: dict[str, int] = Field(default_factory=dict)
    not_null: dict[str, list[str]] = Field(default_factory=dict)


class GroupConfig(BaseModel):
    schedule: str
    freshness_grace_hours: int = 48
    datasets: list[str] = Field(default_factory=list)


class LightcastConfig(BaseModel):
    source_dir: str = "sql/owc"
    defaults: dict[str, str] = Field(default_factory=lambda: {"group": "monthly"})
    groups: dict[str, GroupConfig]
    quality: QualityConfig = Field(default_factory=QualityConfig)

    @model_validator(mode="after")
    def _default_group_exists(self) -> LightcastConfig:
        fallback = self.defaults.get("group", "monthly")
        if fallback not in self.groups:
            raise ValueError(
                f"defaults.group={fallback!r} is not one of groups: {sorted(self.groups)}"
            )
        # A dataset named in two groups would be extracted twice per cycle and
        # billed to Lightcast twice.
        seen: dict[str, str] = {}
        for group_name, group in self.groups.items():
            for ds in group.datasets:
                if ds in seen:
                    raise ValueError(
                        f"dataset {ds!r} is listed in both {seen[ds]!r} and {group_name!r}"
                    )
                seen[ds] = group_name
        return self

    @property
    def default_group(self) -> str:
        return self.defaults.get("group", "monthly")

    def sql_dir(self, root: Path = REPO_ROOT) -> Path:
        return root / self.source_dir

    def all_datasets(self, root: Path = REPO_ROOT) -> list[str]:
        """Every .sql file in source_dir, by stem, sorted.

        Globbing the directory is what the original pipeline did, and keeping
        it means adding a .sql file needs no config edit.
        """
        d = self.sql_dir(root)
        if not d.is_dir():
            raise ConfigError(f"lightcast source_dir does not exist: {d}")
        names = sorted(p.stem for p in d.glob("*.sql"))
        if not names:
            raise ConfigError(f"no .sql files found in {d}")
        return names

    def group_for(self, dataset: str) -> str:
        for group_name, group in self.groups.items():
            if dataset in group.datasets:
                return group_name
        return self.default_group

    def datasets_in_group(self, group: str, root: Path = REPO_ROOT) -> list[str]:
        """Datasets belonging to ``group``, resolved against the files on disk.

        For the default group that means "everything not claimed by another
        group", so a new .sql file is picked up automatically.
        """
        if group not in self.groups:
            raise ConfigError(f"unknown lightcast group {group!r}; known: {sorted(self.groups)}")
        available = self.all_datasets(root)
        named = set(self.groups[group].datasets)
        unknown = sorted(named - set(available))
        if unknown:
            raise ConfigError(
                f"group {group!r} names datasets with no .sql file: {', '.join(unknown)}"
            )
        return [ds for ds in available if self.group_for(ds) == group]


class EnrollmentConfig(BaseModel):
    schedule: str
    page_url: str
    table: str = "enrollment_primary"
    freshness_grace_hours: int = 72
    download_delay_seconds: float = 1.0
    quality: QualityConfig = Field(default_factory=QualityConfig)


class PipelinesConfig(BaseModel):
    lightcast: LightcastConfig
    enrollment: EnrollmentConfig

    @classmethod
    def load(cls, path: Path | str | None = None) -> PipelinesConfig:
        p = Path(path) if path else DEFAULT_PIPELINES_FILE
        if not p.is_file():
            raise ConfigError(f"pipelines config not found: {p}")
        try:
            raw = yaml.safe_load(p.read_text()) or {}
        except yaml.YAMLError as exc:
            raise ConfigError(f"{p} is not valid YAML: {exc}") from exc
        try:
            return cls.model_validate(raw)
        except Exception as exc:
            raise ConfigError(f"{p} is invalid: {exc}") from exc


@functools.lru_cache(maxsize=1)
def get_settings() -> Settings:
    try:
        return Settings()
    except Exception as exc:
        raise ConfigError(f"invalid environment configuration: {exc}") from exc


@functools.lru_cache(maxsize=1)
def get_pipelines_config() -> PipelinesConfig:
    return PipelinesConfig.load(get_settings().pipelines_file)
