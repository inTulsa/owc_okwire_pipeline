# One image, both pipelines, selected at runtime by `owcdata run <pipeline>`.
# Separate images would be tidier but double the build and deploy config for
# no benefit: image size is irrelevant here and one image is far easier for a
# small team to reason about.

FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# uv from its own published image, so the build does not depend on resolving
# the installer itself from PyPI.
COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

WORKDIR /app

# --- dependency layer -------------------------------------------------------
# pyproject.toml plus a package stub is everything `pip install -e .` needs to
# resolve and install the dependency tree. Real source arrives below, so a
# source-only change does not reinstall ~200 MB of wheels.
COPY pyproject.toml README.md ./
RUN mkdir -p src/owcdata && touch src/owcdata/__init__.py
RUN uv pip install -e .

# --- application ------------------------------------------------------------
# The editable install points at src/, so replacing it needs no reinstall.
COPY src/ src/
COPY sql/ sql/
COPY pipelines.yml ./

# Baked at build time so every structured log line and every pipeline_runs row
# names the commit that produced it.
ARG GIT_SHA=unknown
ENV OWC_GIT_SHA=${GIT_SHA}

# Non-root. Cloud Run does not require it, but the enrollment job writes into
# a FUSE mount and a consistently-owned cache is easier to reason about.
RUN useradd --create-home --uid 1001 owcdata \
    && mkdir -p /app/data /app/exports \
    && chown -R owcdata:owcdata /app
USER owcdata

# Fail the build, not the 06:00 run, on a broken image: this parses
# pipelines.yml and all 41 .sql files with no network and no credentials.
RUN owcdata validate

ENTRYPOINT ["owcdata"]
CMD ["--help"]
