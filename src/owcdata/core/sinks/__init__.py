"""Output sinks. ``build_sink`` is the only thing pipelines should need."""

from __future__ import annotations

from owcdata.config import Settings
from owcdata.core.sinks.base import Sink
from owcdata.core.sinks.gcs import GCSSink
from owcdata.core.sinks.local import LocalSink

__all__ = ["GCSSink", "LocalSink", "Sink", "build_sink"]


def build_sink(settings: Settings, pipeline: str) -> Sink:
    """The sink for ``pipeline``, prefixed so the two pipelines' IAM can differ.

    The per-pipeline prefix is load-bearing, not cosmetic: the lightcast
    service account is granted objectAdmin on ``lightcast/`` only and the
    enrollment one on ``enrollment/`` only, so neither can touch the other's
    output.
    """
    if settings.target == "gcs":
        return GCSSink(settings.gcs_raw_bucket, prefix=pipeline)
    return LocalSink(settings.local_output_dir / pipeline)
