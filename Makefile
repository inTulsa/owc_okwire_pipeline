# OWC data platform. `make help` for the list.
.DEFAULT_GOAL := help
SHELL := /bin/bash

VENV       := .venv
PY         := $(VENV)/bin/python
OWCDATA    := $(VENV)/bin/owcdata
ENV        ?= dev
PIPELINE   ?= lightcast
TARGET     ?= local
TF_DIR     := infra/terraform/envs/$(ENV)
TFVARS     := $(TF_DIR)/terraform.tfvars

# project_id and region come from the environment's tfvars rather than being
# duplicated here, so `make build ENV=prod` cannot quietly build into dev
# (gcloud builds submit otherwise uses whatever the default project happens
# to be). Override on the command line if you need to.
tfvar      = $(shell awk -F= '/^[[:space:]]*$(1)[[:space:]]*=/ {gsub(/[" \t]/,"",$$2); print $$2; exit}' $(TFVARS) 2>/dev/null)
PROJECT    ?= $(call tfvar,project_id)
REGION     ?= $(or $(call tfvar,region),us-central1)
IMAGE_TAG  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo untracked)
IMAGE_REPO  = $(REGION)-docker.pkg.dev/$(PROJECT)/okw-images/owcdata
# Mirrors modules/platform/secrets.tf. Terraform owns the container; the value
# is added out of band and never enters Terraform state.
SECRET_NAME = okw-snowflake-password-$(ENV)
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
        diff-enrollment derive-scrape derive-check build deploy set-image which-image image-digest tf-init tf-bootstrap preflight wif-check tf-output tf-plan tf-apply tf-fmt tf-validate clean

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

build: ## Build and push the image with Cloud Build, then print its digest
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)"; exit 1; }
	@echo ">> building $(IMAGE_REPO):$(IMAGE_TAG)"
	gcloud builds submit --config docker/cloudbuild.yaml \
	  --project $(PROJECT) \
	  --substitutions=_REGION=$(REGION),_TAG=$(IMAGE_TAG) \
	  .
	@image=$$($(MAKE) -s --no-print-directory image-digest ENV=$(ENV)) && \
	  echo "" && \
	  echo "image: $$image" && \
	  echo "" && \
	  echo "This pushed the image but did NOT point the jobs at it — a Cloud Run" && \
	  echo "job pins a digest, and terraform ignores changes to it. Next:" && \
	  echo "" && \
	  echo "  make set-image ENV=$(ENV)            # move both jobs onto it" && \
	  echo "  make tf-apply  ENV=$(ENV) TF_ARGS=\"-var=image_digest=$$image\"" && \
	  echo "" && \
	  echo "Or do both in one step next time:  make deploy ENV=$(ENV)" && \
	  echo ""

# Prints ONE line and nothing else, so it composes:
#   IMAGE=$(make -s image-digest ENV=dev)
# Human-friendly guidance lives in `build`, not here — mixing prose into this
# target's output is what made the documented one-liner capture two lines.
# Closes the loop that `make build` alone leaves open.
#
# The Cloud Run job's image is in lifecycle.ignore_changes (so an incident-time
# `gcloud run jobs update --image` is not reverted by the next unrelated
# apply), which also means `terraform apply` will NEVER move a job onto a
# newly built image. Without this target, `make build` pushes a fix and the
# jobs keep running the old digest — silently, because the tag moved but the
# job pins a digest.
set-image: ## Point both Cloud Run jobs at a digest (default: the newest build)
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@image="$(if $(IMAGE),$(IMAGE),$$($(MAKE) -s --no-print-directory image-digest ENV=$(ENV)))"; \
	  case "$$image" in *@sha256:*) ;; *) echo "refusing a non-digest image: $$image" >&2; exit 1;; esac; \
	  for job in okw-lightcast-$(ENV) okw-enrollment-$(ENV); do \
	    echo ">> $$job -> $$image"; \
	    gcloud run jobs update "$$job" --image "$$image" \
	      --region $(REGION) --project $(PROJECT) --quiet >/dev/null; \
	  done; \
	  echo ">> both jobs updated"

deploy: build set-image ## Build the image AND point both jobs at it (the dev loop)
	@echo ""
	@echo ">> deployed. Smoke test:"
	@echo "   gcloud run jobs execute okw-lightcast-$(ENV) --region $(REGION) --project $(PROJECT) \\"
	@echo "     --args=\"run,lightcast,--dataset,dim_area,--limit,1000\" --tasks=1 --wait"

which-image: ## Show the digest each job is currently running vs the newest build
	@printf '  newest build      : %s\n' "$$($(MAKE) -s --no-print-directory image-digest ENV=$(ENV) 2>/dev/null || echo '<none>')"
	@for job in okw-lightcast-$(ENV) okw-enrollment-$(ENV); do \
	  img=$$(gcloud run jobs describe "$$job" --region $(REGION) --project $(PROJECT) \
	    --format='value(spec.template.spec.template.spec.containers[0].image)' 2>/dev/null); \
	  printf '  %-18s: %s\n' "$$job" "$${img:-<not deployed>}"; \
	done

image-digest: ## Print just the digest-pinned image reference (scriptable)
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@digest=$$(gcloud artifacts docker images describe \
	    "$(IMAGE_REPO):$(IMAGE_TAG)" \
	    --project $(PROJECT) --format='value(image_summary.digest)') && \
	  echo "$(IMAGE_REPO)@$$digest"

# -- terraform ---------------------------------------------------------------
tf-init: ## terraform init for $(ENV)
	cd $(TF_DIR) && terraform init

# Breaks the first-deploy cycle: Terraform creates Artifact Registry, but
# `make build` needs Artifact Registry to push to.
#
# Targeted at the REGISTRY ALONE, deliberately. Terraform pulls in that
# resource's dependencies, which is the API enablement — and nothing else. An
# earlier version targeted the whole platform module and broke on unrelated
# monitoring resources even though the registry itself was created fine; a
# bootstrap step should have the smallest blast radius that unblocks the
# build, not the largest.
#
# Enabling the APIs here is a second benefit: Cloud Build's service agent gets
# provisioned well before `make build` runs, which is what otherwise produces
# a PERMISSION_DENIED on the first submit.
#
# The placeholder digest satisfies the pipeline module's "must be a digest"
# validation, which Terraform evaluates even for resources -target excludes.
# No Cloud Run job is created by this step.
tf-bootstrap: ## First deploy only: create Artifact Registry + the secret container
	cd $(TF_DIR) && terraform init && terraform apply \
	  -target=module.platform.google_artifact_registry_repository.images \
	  -target=module.platform.google_secret_manager_secret.snowflake_password \
	  -var='image_digest=bootstrap@sha256:0000000000000000000000000000000000000000000000000000000000000000'
	@echo ""
	@echo ">> Artifact Registry ready, and the secret container exists."
	@echo "   Next:"
	@echo "     1. printf '%s' 'THE_PASSWORD' | gcloud secrets versions add $(SECRET_NAME) --data-file=- --project $(PROJECT)"
	@echo "     2. make build ENV=$(ENV)"

tf-fmt: ## terraform fmt across all modules and envs
	terraform fmt -recursive infra/terraform

tf-validate: ## terraform validate for $(ENV)
	cd $(TF_DIR) && terraform validate

# The lightcast Cloud Run job mounts SNOWFLAKE_PASSWORD from
# $(SECRET_NAME)/versions/latest. Terraform creates the secret CONTAINER but
# never the value — that is deliberate, so the password stays out of Terraform
# state. But "latest" cannot resolve to nothing: with no version, job creation
# fails with "Secret .../versions/latest was not found" several minutes into
# the apply, after most other resources have already been created.
#
# One second here beats that. SKIP_PREFLIGHT=1 bypasses it.
# The WIF attribute_condition is the line that keeps every other GitHub
# repository out of this project, and GitHub's assertion.repository claim
# preserves the owner's exact casing. A mismatch fails CLOSED — deploys stop
# authenticating — so it is safe but silent, and easy to lose an afternoon to.
wif-check: ## Verify github_repository in tfvars matches the actual git remote, exactly
	@remote=$$(git remote get-url origin 2>/dev/null \
	    | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$$##'); \
	  configured=$$(awk -F= '/^[[:space:]]*github_repository[[:space:]]*=/ {gsub(/[" \t]/,"",$$2); print $$2; exit}' $(TFVARS)); \
	  echo "  git remote : $${remote:-<none>}"; \
	  echo "  $(ENV) tfvars : $${configured:-<none>}"; \
	  if [ -z "$$remote" ]; then \
	    echo "  -- no git remote to compare against; verify by hand"; \
	  elif [ "$$remote" = "$$configured" ]; then \
	    echo "  OK: exact match"; \
	  elif [ "$$(echo $$remote | tr A-Z a-z)" = "$$(echo $$configured | tr A-Z a-z)" ]; then \
	    echo ""; \
	    echo "  CASE MISMATCH. GitHub's assertion.repository claim preserves the"; \
	    echo "  owner's casing, and the CEL comparison is case-sensitive, so this"; \
	    echo "  condition will never match and GitHub Actions deploys will fail to"; \
	    echo "  authenticate. Set github_repository to exactly: $$remote"; \
	    echo ""; exit 1; \
	  else \
	    echo ""; \
	    echo "  MISMATCH: tfvars names a different repository than the remote."; \
	    echo "  Set github_repository to exactly: $$remote"; \
	    echo ""; exit 1; \
	  fi

preflight: wif-check ## Check the Snowflake secret has a version before applying
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@if [ -n "$(SKIP_PREFLIGHT)" ]; then echo ">> preflight skipped"; exit 0; fi
	@if ! gcloud secrets describe $(SECRET_NAME) --project $(PROJECT) >/dev/null 2>&1; then \
	  echo ""; \
	  echo "The secret container $(SECRET_NAME) does not exist yet."; \
	  echo "Run:  make tf-bootstrap ENV=$(ENV)"; \
	  echo ""; exit 1; \
	fi
	@versions=$$(gcloud secrets versions list $(SECRET_NAME) --project $(PROJECT) \
	    --filter='state:ENABLED' --format='value(name)' 2>/dev/null | wc -l | tr -d ' '); \
	  if [ "$$versions" = "0" ]; then \
	    echo ""; \
	    echo "$(SECRET_NAME) has no enabled version, so the lightcast job cannot"; \
	    echo "resolve SNOWFLAKE_PASSWORD from versions/latest and its creation will fail."; \
	    echo ""; \
	    echo "Store the password first:"; \
	    echo "  printf '%s' 'THE_PASSWORD' | \\"; \
	    echo "    gcloud secrets versions add $(SECRET_NAME) --data-file=- --project $(PROJECT)"; \
	    echo ""; \
	    exit 1; \
	  fi; \
	  echo ">> preflight OK: $(SECRET_NAME) has $$versions enabled version(s)"

# Every other tf operation here cds into the env directory for you, so a bare
# `terraform output` run from the repo root reports "No outputs found" — which
# reads like the outputs are missing rather than like you are in the wrong
# directory. This removes that footgun.
# `terraform output -raw` deliberately omits a trailing newline, which is right
# for `$(...)` capture and wrong for reading: the value runs straight into the
# next prompt or error. The `&& echo` restores it without affecting capture,
# since command substitution strips trailing newlines anyway.
tf-output: ## Show terraform outputs for $(ENV). Add NAME=<output> for one value.
	@cd $(TF_DIR) && $(if $(NAME),terraform output -raw $(NAME) && echo,terraform output)

tf-plan: ## terraform plan for $(ENV). Add TF_ARGS='-var=image_digest=...'
	cd $(TF_DIR) && terraform plan $(TF_ARGS)

tf-apply: preflight ## terraform apply for $(ENV). Add TF_ARGS='-var=image_digest=...'
	cd $(TF_DIR) && terraform apply $(TF_ARGS)

clean: ## Remove caches and local pipeline output
	rm -rf .mypy_cache .ruff_cache .pytest_cache exports .owcdata-local
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
