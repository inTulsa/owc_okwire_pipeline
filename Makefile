# OWC data platform. `make help` for the list.
.DEFAULT_GOAL := help
SHELL := /bin/bash

VENV       := .venv
PY         := $(VENV)/bin/python
OWCDATA    := $(VENV)/bin/owcdata
ENV        ?= dev
PIPELINE   ?= lightcast
TARGET     ?= local
REGION     ?= us-central1
TF_DIR     := infra/terraform/envs/$(ENV)
ORIGINAL   := tests/fixtures/primary_enrollment_data_script.original.py
SCRAPE     := src/owcdata/pipelines/enrollment/scrape.py

# Optional: DATASET=dim_area LIMIT=1000 GROUP=monthly
RUN_ARGS :=
ifdef DATASET
RUN_ARGS += --dataset $(DATASET)
endif
ifdef GROUP
RUN_ARGS += --group $(GROUP)
endif
ifdef LIMIT
RUN_ARGS += --limit $(LIMIT)
endif

.PHONY: help setup run validate test test-all lint fmt typecheck check \
        diff-enrollment derive-scrape derive-check build tf-init tf-plan tf-apply tf-fmt tf-validate clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables: PIPELINE=lightcast|enrollment  TARGET=local|gcs  ENV=dev|prod"
	@echo "             DATASET=<name>  GROUP=<group>  LIMIT=<n>"
	@echo ""
	@echo "  Examples:"
	@echo "    make run PIPELINE=lightcast DATASET=dim_area LIMIT=1000"
	@echo "    make run PIPELINE=enrollment TARGET=local"

setup: ## Create the venv and install everything, including dev tools
	uv venv --python 3.12
	uv pip install -e ".[dev]"
	@test -f .env || { cp .env.example .env; echo ">> wrote .env from .env.example — fill in your Snowflake credentials"; }
	@echo ">> ready. next: make validate"

run: ## Run a pipeline (see Variables above)
	$(OWCDATA) run $(PIPELINE) --target $(TARGET) --env $(ENV) $(RUN_ARGS)

validate: ## Config + SQL parse. No network, no credentials.
	$(OWCDATA) validate

test: ## Unit tests only (no network)
	$(VENV)/bin/pytest tests/unit -q

test-all: ## Unit + integration. Needs Snowflake credentials and a dev GCP project.
	$(VENV)/bin/pytest -q -m "integration or not integration"

lint: ## ruff
	$(VENV)/bin/ruff check src tests

fmt: ## ruff format + fix
	$(VENV)/bin/ruff format src tests
	$(VENV)/bin/ruff check --fix src tests

typecheck: ## mypy
	$(VENV)/bin/mypy

check: lint typecheck derive-check validate test ## Everything CI runs on a PR

diff-enrollment: ## Show every change made to the carried-over enrollment script
	@diff -u $(ORIGINAL) $(SCRAPE) || true

derive-scrape: ## Regenerate scrape.py from the pristine original
	$(PY) scripts/derive_scrape.py

derive-check: ## Verify scrape.py matches its derivation (CI runs this)
	$(PY) scripts/derive_scrape.py --check

build: ## Build and push the image with Cloud Build (docker is not installed locally)
	gcloud builds submit --config docker/cloudbuild.yaml \
	  --substitutions=_ENV=$(ENV),SHORT_SHA=$$(git rev-parse --short HEAD) .

# -- terraform ---------------------------------------------------------------
tf-init: ## terraform init for $(ENV)
	cd $(TF_DIR) && terraform init

tf-fmt: ## terraform fmt across all modules and envs
	terraform fmt -recursive infra/terraform

tf-validate: ## terraform validate for $(ENV)
	cd $(TF_DIR) && terraform validate

tf-plan: ## terraform plan for $(ENV)
	cd $(TF_DIR) && terraform plan

tf-apply: ## terraform apply for $(ENV)
	cd $(TF_DIR) && terraform apply

clean: ## Remove caches and local pipeline output
	rm -rf .mypy_cache .ruff_cache .pytest_cache exports .owcdata-local
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
