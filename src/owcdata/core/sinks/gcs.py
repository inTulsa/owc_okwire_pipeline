"""GCS sink — streaming resumable uploads, no local staging."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from typing import IO, Any

from owcdata.core.sinks.base import Sink

# Resumable-upload chunk size. GCS requires a multiple of 256 KiB. This is the
# buffer held in memory per open stream — the ~64 MiB/open-file figure in the
# design notes — so it stays well clear of a 2 GiB task.
_CHUNK_BYTES = 16 * 1024 * 1024


class GCSSink(Sink):
    def __init__(self, bucket: str, prefix: str = "", client: Any | None = None) -> None:
        # google.cloud is a namespace package, which mypy cannot resolve
        # attribute-wise even with stubs ignored.
        from google.cloud import storage  # type: ignore[attr-defined]

        self.bucket_name = bucket
        self.prefix = prefix.strip("/")
        self._client = client or storage.Client()
        self._bucket = self._client.bucket(bucket)

    def _key(self, rel_path: str) -> str:
        rel = rel_path.lstrip("/")
        return f"{self.prefix}/{rel}" if self.prefix else rel

    def uri(self, rel_path: str) -> str:
        return f"gs://{self.bucket_name}/{self._key(rel_path)}"

    @contextmanager
    def open_write(self, rel_path: str) -> Iterator[IO[bytes]]:
        blob = self._bucket.blob(self._key(rel_path))
        # BlobWriter implements write() and tell(), which is all pyarrow's
        # ParquetWriter needs to record row-group offsets and the footer.
        with blob.open("wb", chunk_size=_CHUNK_BYTES) as fh:
            yield fh  # type: ignore[misc]

    def write_bytes(self, rel_path: str, data: bytes) -> str:
        blob = self._bucket.blob(self._key(rel_path))
        blob.upload_from_string(data)
        return self.uri(rel_path)

    def upload_file(self, rel_path: str, local_path: str) -> str:
        blob = self._bucket.blob(self._key(rel_path))
        blob.chunk_size = _CHUNK_BYTES
        blob.upload_from_filename(local_path)
        return self.uri(rel_path)

    def exists(self, rel_path: str) -> bool:
        return self._bucket.blob(self._key(rel_path)).exists()
