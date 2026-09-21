"""Dataset resolution and query preparation for the lightcast pipeline.

Nothing here modifies a file on disk. ``sql/owc/`` is verbatim and stays that
way; ``--limit`` wraps the text in memory only.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from owcdata.config import REPO_ROOT, LightcastConfig
from owcdata.errors import ConfigError

# Trailing semicolons plus any whitespace after them. Seven of the 41 files
# end in one (dim_area, dim_company, dim_edulevels, dim_schools, dim_skills,
# fact_completions, fact_completions_lagged) and a semicolon inside a
# subquery is a syntax error, so it has to come off before wrapping.
_TRAILING_SEMICOLONS = re.compile(r"(?:\s*;)+\s*\Z")

# For the safety scan below. Order matters: block comments first, then line
# comments, then single-quoted literals (with '' escaping).
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
_LINE_COMMENT = re.compile(r"--[^\n]*")
_STRING_LITERAL = re.compile(r"'(?:[^']|'')*'")


@dataclass(frozen=True)
class Dataset:
    """One .sql file: its name, its schedule group, and where it lives."""

    name: str
    group: str
    sql_path: Path

    def read_sql(self) -> str:
        return self.sql_path.read_text(encoding="utf-8")

    def query(self, limit: int | None = None) -> str:
        return prepare_query(self.read_sql(), limit)


def strip_trailing_semicolon(sql: str) -> str:
    return _TRAILING_SEMICOLONS.sub("", sql)


def _blank_comments_and_strings(sql: str) -> str:
    """Replace comments and string literals with same-length whitespace.

    Same length so character offsets still line up with the original text.
    """

    def blank(match: re.Match[str]) -> str:
        return re.sub(r"[^\n]", " ", match.group(0))

    for pattern in (_BLOCK_COMMENT, _LINE_COMMENT, _STRING_LITERAL):
        sql = pattern.sub(blank, sql)
    return sql


def statement_semicolons(sql: str) -> list[int]:
    """Offsets of semicolons that actually terminate a statement.

    Comment-aware on purpose. Four of the 41 files carry a semicolon inside a
    ``--`` comment ("detailed SOC only; avoids aggregates like 00-0000" and
    three variants of "ADD quarterly; the past 3 months"), which is harmless
    and must not be mistaken for a second statement — a naive scan for ``;``
    flags those files and blocks CI for no reason.
    """
    scrubbed = _blank_comments_and_strings(sql)
    return [m.start() for m in re.finditer(";", scrubbed)]


def is_single_statement(sql: str) -> bool:
    """True if ``sql`` is one statement, so ``--limit`` can safely wrap it.

    A trailing semicolon is fine — ``prepare_query`` strips it. A semicolon
    with SQL after it is not.
    """
    body = strip_trailing_semicolon(sql)
    return not statement_semicolons(body)


def prepare_query(sql: str, limit: int | None = None) -> str:
    """The SQL as it will be sent to Snowflake.

    With no ``limit`` this is the file's own text, unchanged apart from
    trailing whitespace. With a ``limit`` the whole query becomes a subquery.
    All 41 files are verified single-statement, so wrapping is safe; the
    newline before ``)`` matters because several files end in a ``--`` line
    comment that would otherwise swallow it.
    """
    body = strip_trailing_semicolon(sql).rstrip()
    if limit is None:
        return body
    if limit <= 0:
        raise ConfigError(f"--limit must be positive, got {limit}")
    if statement_semicolons(body):
        # Wrapping a multi-statement script produces a syntax error against a
        # billed warehouse. Refuse here instead.
        raise ConfigError("cannot apply --limit: the query contains more than one statement")
    return f"SELECT * FROM (\n{body}\n) AS _owc_limited\nLIMIT {int(limit)}"


def resolve(
    config: LightcastConfig,
    *,
    group: str | None = None,
    dataset: str | None = None,
    root: Path = REPO_ROOT,
) -> list[Dataset]:
    """The datasets this invocation should extract.

    Exactly one of ``group`` or ``dataset`` narrows the set; neither means
    every .sql file in ``source_dir``.
    """
    if dataset and group:
        raise ConfigError("pass --dataset or --group, not both")

    sql_dir = config.sql_dir(root)

    if dataset:
        name = dataset[:-4] if dataset.endswith(".sql") else dataset
        path = sql_dir / f"{name}.sql"
        if not path.is_file():
            available = ", ".join(config.all_datasets(root))
            raise ConfigError(f"no such dataset {name!r} in {sql_dir}. Available: {available}")
        return [Dataset(name=name, group=config.group_for(name), sql_path=path)]

    names = config.datasets_in_group(group, root) if group else config.all_datasets(root)
    return [
        Dataset(name=n, group=config.group_for(n), sql_path=sql_dir / f"{n}.sql") for n in names
    ]


def shard(datasets: list[Dataset], task_index: int, task_count: int) -> list[Dataset]:
    """The slice of ``datasets`` this Cloud Run task owns.

    One dataset per task when ``task_count`` matches the dataset count, which
    is how Terraform sizes it. Deliberately not modulo round-robin: a single
    failed query fails its whole task, so a task holding several datasets
    would re-run — and re-bill Lightcast for — the queries that already
    succeeded. One dataset per task makes a retry surgical.

    If task_count is smaller than the dataset count (a hand-run execution, or
    a group that grew after the last deploy) the remainder is distributed
    contiguously rather than dropped.
    """
    if task_count <= 1:
        return datasets
    if not 0 <= task_index < task_count:
        raise ConfigError(f"task_index {task_index} out of range for task_count {task_count}")
    n = len(datasets)
    base, extra = divmod(n, task_count)
    start = task_index * base + min(task_index, extra)
    size = base + (1 if task_index < extra else 0)
    return datasets[start : start + size]
