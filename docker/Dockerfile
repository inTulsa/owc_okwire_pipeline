# One image, both pipelines, selected at runtime by `owcdata run <pipeline>`.
# Separate images would be tidier but double the build and deploy config for
# no benefit: image size is irrelevant here and one image is far easier for a
# small team to reason about.

# Pinned by DIGEST, not by tag. `python:3.12-slim-bookworm` moves whenever
# upstream rebuilds it, so with a tag the dev branch and the prod branch can
# build the same source onto different base images weeks apart. Under
# branch-per-environment nothing carries the tested artifact from one project
# to the other, so "same commit" has to mean "same image" — and only a digest
# makes that true. Refresh deliberately with `make base-digest`.
FROM python:3.12-slim-bookworm@sha256:392307d22300de8b5986851a12d9176dfc0fc073e65bf6523ebd7dcbeb23564e

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
# Installed from a fully pinned requirements.txt (194 transitive pins), not
# from pyproject.toml's version ranges. The ranges are right for development
# and wrong for a release artifact: `pandas>=2.2,<3.0` resolves to whatever
# is newest at build time, so two builds of one commit can ship different
# dependency trees.
#
# This is not hypothetical here. xlrd is the only reader for the pre-2019
# .xls workbooks still linked on oklahoma.gov, and losing or changing it in a
# rebuild drops the oldest fiscal years SILENTLY — the scrape succeeds with
# fewer years. Pinning is what stops a rebuild being a data change.
#
# Regenerate with `make lock` after editing pyproject.toml; CI checks it.
COPY pyproject.toml README.md requirements.txt ./
RUN mkdir -p src/owcdata && touch src/owcdata/__init__.py
RUN uv pip install -r requirements.txt

# --no-deps: requirements.txt above already resolved the whole tree, and
# without it uv would re-resolve the ranges in pyproject.toml and undo the
# pinning this layer exists for.
RUN uv pip install -e . --no-deps

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
