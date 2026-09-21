"""Filesystem sink — what ``--target local`` writes through."""

from __future__ import annotations

import shutil
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import IO

from owcdata.core.sinks.base import Sink


class LocalSink(Sink):
    def __init__(self, root: Path | str) -> None:
        self.root = Path(root).resolve()

    def _path(self, rel_path: str) -> Path:
        p = (self.root / rel_path).resolve()
        # A dataset name is interpolated into rel_path, so refuse anything
        # that resolves outside the root rather than trusting the caller.
        if not p.is_relative_to(self.root):
            raise ValueError(f"path escapes sink root: {rel_path}")
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def uri(self, rel_path: str) -> str:
        return str(self.root / rel_path)

    @contextmanager
    def open_write(self, rel_path: str) -> Iterator[IO[bytes]]:
        with self._path(rel_path).open("wb") as fh:
            yield fh

    def write_bytes(self, rel_path: str, data: bytes) -> str:
        p = self._path(rel_path)
        p.write_bytes(data)
        return str(p)

    def upload_file(self, rel_path: str, local_path: str) -> str:
        p = self._path(rel_path)
        shutil.copy2(local_path, p)
        return str(p)
