"""The sink contract both pipelines write through.

One interface, two implementations: a directory on a laptop and a GCS bucket
prefix. ``--target local`` selects the first and reproduces the original
pipelines' on-disk behavior; Cloud Run selects the second.

Everything here is *streaming*. Cloud Run's filesystem is in-memory in both
execution generations with no size limit, so a task that stages a 2.7 GB
Parquet file on "disk" before uploading is really holding 2.7 GB of RAM and
will be killed. Writers therefore hand bytes straight to the destination.
"""

from __future__ import annotations

import abc
from collections.abc import Iterator
from contextlib import contextmanager
from typing import IO


class Sink(abc.ABC):
    """A namespace of relative paths that can be written to once, streaming."""

    @abc.abstractmethod
    def uri(self, rel_path: str) -> str:
        """The fully-qualified location ``rel_path`` resolves to, for logging."""

    @abc.abstractmethod
    @contextmanager
    def open_write(self, rel_path: str) -> Iterator[IO[bytes]]:
        """Yield a binary, write-only, streaming file object for ``rel_path``."""

    @abc.abstractmethod
    def write_bytes(self, rel_path: str, data: bytes) -> str:
        """Write ``data`` in one shot. Returns the URI written."""

    @abc.abstractmethod
    def upload_file(self, rel_path: str, local_path: str) -> str:
        """Copy an existing local file to ``rel_path``. Returns the URI written."""

    def write_text(self, rel_path: str, text: str) -> str:
        return self.write_bytes(rel_path, text.encode("utf-8"))
