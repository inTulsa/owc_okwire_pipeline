"""Dataset resolution, --limit wrapping, and task sharding."""

from __future__ import annotations

import pytest

from owcdata.config import PipelinesConfig
from owcdata.errors import ConfigError
from owcdata.pipelines.lightcast.datasets import (
    is_single_statement,
    prepare_query,
    resolve,
    shard,
    statement_semicolons,
    strip_trailing_semicolon,
)

# The seven files that end in a semicolon. A semicolon inside a subquery is a
# syntax error, so --limit must strip it.
SEMICOLON_FILES = [
    "dim_area",
    "dim_company",
    "dim_edulevels",
    "dim_schools",
    "dim_skills",
    "fact_completions",
    "fact_completions_lagged",
]


@pytest.fixture(scope="module")
def lc():
    return PipelinesConfig.load().lightcast


def test_every_sql_file_is_single_statement_so_limit_is_safe(lc):
    for ds in resolve(lc):
        assert is_single_statement(ds.read_sql()), f"{ds.name}.sql is not a single statement"


def test_the_seven_semicolon_files_are_still_the_seven(lc):
    """If this list changes, --limit just started or stopped mattering for a file."""
    found = sorted(ds.name for ds in resolve(lc) if ds.read_sql().rstrip().endswith(";"))
    assert found == sorted(SEMICOLON_FILES)


@pytest.mark.parametrize("name", SEMICOLON_FILES)
def test_limit_wrapping_strips_the_trailing_semicolon(lc, name):
    wrapped = resolve(lc, dataset=name)[0].query(limit=100)
    assert not statement_semicolons(wrapped)
    assert wrapped.endswith("LIMIT 100")
    assert "_owc_limited" in wrapped


def test_semicolons_inside_comments_are_not_statement_terminators():
    """Four of the 41 files carry one. A naive scan would flag them wrongly."""
    sql = "SELECT 1 AS x -- detailed SOC only; avoids aggregates\nFROM t"
    assert statement_semicolons(sql) == []
    assert is_single_statement(sql)
    assert "LIMIT 5" in prepare_query(sql, limit=5)


def test_semicolons_inside_string_literals_are_not_terminators():
    sql = "SELECT 'a;b' AS x FROM t"
    assert statement_semicolons(sql) == []


def test_block_comment_semicolon_is_not_a_terminator():
    sql = "/* note; here */ SELECT 1 FROM t"
    assert statement_semicolons(sql) == []


def test_real_multi_statement_is_detected_and_refused():
    sql = "SELECT 1 FROM a; SELECT 2 FROM b"
    assert not is_single_statement(sql)
    with pytest.raises(ConfigError, match="more than one statement"):
        prepare_query(sql, limit=10)


def test_no_limit_returns_the_file_text_unchanged(lc):
    ds = resolve(lc, dataset="fact_jobs")[0]
    assert ds.query() == ds.read_sql().rstrip()


def test_limit_wrapping_never_modifies_the_file_on_disk(lc):
    ds = resolve(lc, dataset="dim_area")[0]
    before = ds.sql_path.read_bytes()
    ds.query(limit=1)
    assert ds.sql_path.read_bytes() == before


@pytest.mark.parametrize("bad", [0, -1])
def test_nonpositive_limit_is_rejected(bad):
    with pytest.raises(ConfigError, match="must be positive"):
        prepare_query("SELECT 1", limit=bad)


def test_strip_trailing_semicolon_handles_whitespace_and_repeats():
    assert strip_trailing_semicolon("SELECT 1 ;\n\n") == "SELECT 1"
    assert strip_trailing_semicolon("SELECT 1 ; ;  ") == "SELECT 1"
    assert strip_trailing_semicolon("SELECT 1") == "SELECT 1"


def test_unknown_dataset_names_the_alternatives(lc):
    with pytest.raises(ConfigError, match="dim_area"):
        resolve(lc, dataset="dim_aera")


def test_dataset_accepts_a_sql_suffix(lc):
    assert resolve(lc, dataset="dim_area.sql")[0].name == "dim_area"


def test_dataset_and_group_together_are_rejected(lc):
    with pytest.raises(ConfigError, match="not both"):
        resolve(lc, dataset="dim_area", group="monthly")


def test_one_dataset_per_task_when_task_count_matches(lc):
    datasets = resolve(lc)
    for i in range(len(datasets)):
        mine = shard(datasets, i, len(datasets))
        assert len(mine) == 1
        assert mine[0].name == datasets[i].name


def test_sharding_is_a_partition_at_any_task_count(lc):
    """Every dataset exactly once — a lost dataset silently stops publishing."""
    datasets = resolve(lc)
    for task_count in (1, 2, 4, 7, 40, 41):
        seen = [d.name for i in range(task_count) for d in shard(datasets, i, task_count)]
        assert seen == [d.name for d in datasets], f"broken at task_count={task_count}"


def test_more_tasks_than_datasets_gives_empty_tasks_not_errors(lc):
    datasets = resolve(lc)
    sizes = [len(shard(datasets, i, 50)) for i in range(50)]
    assert sum(sizes) == len(datasets)
    assert sizes.count(0) == 50 - len(datasets)


def test_task_index_out_of_range_is_an_error(lc):
    with pytest.raises(ConfigError, match="out of range"):
        shard(resolve(lc), 5, 4)
