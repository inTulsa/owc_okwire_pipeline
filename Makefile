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
# sub(/\#.*/) first: awk splits on "=", so $$2 is everything up to the next
# one — including a trailing `# comment`, whose spaces the gsub then strips
# and glues onto the value. `billing_budget_amount = 0  # off` parsed as
# "0#off", which is not "0", so every guard reading it took the wrong branch
# silently.
#
# The backslash before # is for MAKE, not awk: an unescaped # inside
# $(shell ...) starts a make comment and truncates the call, which reports
# as "unterminated call to function 'shell': missing ')'".
tfvar      = $(shell awk -F= '/^[[:space:]]*$(1)[[:space:]]*=/ {sub(/\#.*/,"",$$2); gsub(/[" \t]/,"",$$2); print $$2; exit}' $(TFVARS) 2>/dev/null)
PROJECT    ?= $(call tfvar,project_id)
REGION     ?= $(or $(call tfvar,region),us-central1)
IMAGE_TAG  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo untracked)
# Every name below mirrors the OMES convention in
# infra/terraform/modules/*/naming.tf: <type>-<name_prefix>-<qualifier>-<seq>.
# They are derived from the one name_prefix in that environment's tfvars
# rather than spelled out, so correcting an abbreviation in Terraform does
# not leave the Makefile pointing at resources that no longer exist.
# Defaults to the project id, which is what both environments use. Override
# only if a project id is too long for a service account id (30-char cap):
#   make up ENV=dev PROJECT=long-project-name NAME_PREFIX=shorter
NAME_PREFIX ?= $(PROJECT)
IMAGE_REPO  = $(REGION)-docker.pkg.dev/$(PROJECT)/ar-$(NAME_PREFIX)-images-1/owcdata
REGISTRY_ID = ar-$(NAME_PREFIX)-images-1
LIGHTCAST_JOB  = cr-$(NAME_PREFIX)-lightcast-1
ENROLLMENT_JOB = cr-$(NAME_PREFIX)-enrollment-1
# Mirrors modules/platform/secrets.tf. Terraform owns the container; the value
# is added out of band and never enters Terraform state.
SECRET_NAME = sm-$(NAME_PREFIX)-snowflake-password-1
# Cloud Build runs as this rather than the Compute Engine default SA. Mirrors
# modules/platform/iam.tf.
BUILD_SA    = sa-$(NAME_PREFIX)-build-1@$(PROJECT).iam.gserviceaccount.com
# A mirror of this repo inside the project, for anyone who cannot clone from
# GitHub. Created by infra/gcloud/01-admin-identities.sh, not by Terraform.
SOURCE_BUCKET = gcs-$(NAME_PREFIX)-source-1
# Created by infra/gcloud/01-admin-identities.sh, which derives it from the
# project id the same way. Passed to terraform at init rather than written
# into backend.tf, so aiming an apply at another project is one variable.
STATE_BUCKET ?= gcs-$(PROJECT)-tfstate-1

# Supplied to every terraform invocation. project_id and name_prefix come
# from here rather than only from tfvars so that PROJECT= on the command line
# reaches terraform AND the gcloud steps, which read these same variables.
# Passing -var to terraform alone would create identities in one project and
# apply to another.
TF_BACKEND = -backend-config="bucket=$(STATE_BUCKET)" -backend-config="prefix=env/$(ENV)"
TF_VARS    = -var=project_id=$(PROJECT) -var=name_prefix=$(NAME_PREFIX)
# Who runs terraform. Defaults to the active gcloud account, which is right
# for a hand deploy; override when OMES attaches their own pipeline identity:
#   make iam-check ENV=dev TF_PRINCIPAL=serviceAccount:tf@omes-proj.iam.gserviceaccount.com
TF_PRINCIPAL ?= user:$(shell gcloud config get-value account 2>/dev/null)
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

.PHONY: help setup run validate test test-all lint fmt typecheck check auth-check doctor \
        diff-enrollment derive-scrape derive-check lock lock-check docs-check shell-check base-digest build deploy set-image which-image image-digest tf-init tf-bootstrap preflight verify-separation env-exports tf-output tf-plan tf-apply tf-fmt tf-validate clean \
        access-check prep omes-request omes-script gcloud-admin gcloud-admin-dry-run iam-check names-check smoke up source-push \
        tf-check install-terraform

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

# Run this BEFORE anything else on a new machine. A toolchain problem hit in
# the middle of a GCP setup does not look like a toolchain problem: a missing
# bq component surfaces as a failed query, and Application Default
# Credentials pointed at the wrong project surface as "bucket doesn't exist".
doctor: ## Check this machine has the tools and credentials the repo needs
	@scripts/doctor.sh

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

# The docs are the handoff artifact — OMES runs this project from them, with
# nobody to ask when a command turns out not to exist. Several doc/code
# couplings were introduced at once (make targets, the naming convention,
# scripts, terraform outputs) and they all rot silently: nothing fails until
# a person follows the instructions, by which point you are not there.
shell-check: ## Verify every shell helper the scripts call is actually defined
	$(PY) scripts/shell-check.py

docs-check: ## Verify the docs only reference targets, outputs and scripts that exist
	@python3 scripts/docs-check.py

check: lint typecheck derive-check lock-check docs-check shell-check validate test ## The full gate. Run before every commit.

diff-enrollment: ## Show every change made to the carried-over enrollment script
	@diff -u $(ORIGINAL) $(SCRAPE) || true

derive-scrape: ## Regenerate scrape.py from the pristine original
	$(PY) scripts/derive_scrape.py

derive-check: ## Verify scrape.py matches its derivation (part of `make check`)
	$(PY) scripts/derive_scrape.py --check

build: auth-check ## Build and push the image with Cloud Build, then print its digest
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)"; exit 1; }
	@echo ">> building $(IMAGE_REPO):$(IMAGE_TAG)"
	gcloud builds submit --config docker/cloudbuild.yaml \
	  --project $(PROJECT) \
	  --substitutions=_REGION=$(REGION),_TAG=$(IMAGE_TAG),_BUILD_SA=$(BUILD_SA),_REPOSITORY=$(REGISTRY_ID) \
	  .
	@image=$$($(MAKE) -s --no-print-directory image-digest ENV=$(ENV)) && \
	  echo "" && \
	  echo "image: $$image" && \
	  echo "" && \
	  echo "This pushed the image but did NOT point the jobs at it — a Cloud Run" && \
	  echo "job pins a digest, and terraform ignores changes to it." && \
	  echo "" && \
	  echo "If this environment has never been stood up, the jobs do not exist" && \
	  echo "yet and the command is:  make up ENV=$(ENV)" && \
	  echo "" && \
	  echo "Otherwise:" && \
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
set-image: auth-check ## Point both Cloud Run jobs at a digest (default: the newest build)
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@image="$(if $(IMAGE),$(IMAGE),$$($(MAKE) -s --no-print-directory image-digest ENV=$(ENV)))"; \
	  case "$$image" in *@sha256:*) ;; *) echo "refusing a non-digest image: $$image" >&2; exit 1;; esac; \
	  failed=""; \
	  for job in $(LIGHTCAST_JOB) $(ENROLLMENT_JOB); do \
	    echo ">> $$job -> $$image"; \
	    if ! gcloud run jobs update "$$job" --image "$$image" \
	         --region $(REGION) --project $(PROJECT) --quiet >/dev/null 2>&1; then \
	      failed="$$failed $$job"; \
	    fi; \
	  done; \
	  if [ -n "$$failed" ]; then \
	    echo "" >&2; \
	    echo "  Could not update:$$failed" >&2; \
	    echo "" >&2; \
	    if ! gcloud run jobs describe $(LIGHTCAST_JOB) --region $(REGION) \
	         --project $(PROJECT) >/dev/null 2>&1; then \
	      echo "  The Cloud Run jobs do not exist in $(PROJECT) yet." >&2; \
	      echo "" >&2; \
	      echo "  Terraform creates them, and 'make deploy' does not run Terraform —" >&2; \
	      echo "  it only builds an image and points existing jobs at it. On an" >&2; \
	      echo "  environment that has not been stood up yet, the command is:" >&2; \
	      echo "" >&2; \
	      echo "    make up ENV=$(ENV)" >&2; \
	      echo "" >&2; \
	      echo "  That runs tf-bootstrap, build, tf-apply, set-image and the" >&2; \
	      echo "  separation check, in that order. The image you just built is" >&2; \
	      echo "  reused, so nothing is wasted." >&2; \
	    else \
	      echo "  The jobs exist, so this is not a missing-environment problem." >&2; \
	      echo "  Re-run without the output suppressed to see why:" >&2; \
	      echo "" >&2; \
	      echo "    gcloud run jobs update $(LIGHTCAST_JOB) --image $$image \\" >&2; \
	      echo "      --region $(REGION) --project $(PROJECT)" >&2; \
	    fi; \
	    echo "" >&2; \
	    exit 1; \
	  fi; \
	  echo ">> both jobs updated"

deploy: build set-image ## Build the image AND point both jobs at it (the dev loop)
	@echo ""
	@echo ">> deployed. Smoke test:"
	@echo "   gcloud run jobs execute $(LIGHTCAST_JOB) --region $(REGION) --project $(PROJECT) \\"
	@echo "     --args=\"run,lightcast,--dataset,dim_area,--limit,1000\" --tasks=1 --wait"

which-image: auth-check ## Show the digest each job is currently running vs the newest build
	@printf '  newest build      : %s\n' "$$($(MAKE) -s --no-print-directory image-digest ENV=$(ENV) 2>/dev/null || echo '<none>')"
	@for job in $(LIGHTCAST_JOB) $(ENROLLMENT_JOB); do \
	  img=$$(gcloud run jobs describe "$$job" --region $(REGION) --project $(PROJECT) \
	    --format='value(spec.template.spec.template.spec.containers[0].image)' 2>/dev/null); \
	  printf '  %-18s: %s\n' "$$job" "$${img:-<not deployed>}"; \
	done

# Resolves :$(IMAGE_TAG) — the current git short SHA — and falls back to
# :latest when that tag does not exist.
#
# The fallback matters because committing AFTER a build moves HEAD, so the
# SHA tag no longer matches anything and this returned nothing at all, which
# then broke `set-image`, `deploy`, and `which-image` with an unhelpful
# "<none>". The warning goes to stderr so stdout stays clean for
# `IMAGE=$(make -s image-digest ...)`.
auth-check: ## Verify the gcloud CLI has usable credentials
	@scripts/require-gcloud-auth.sh

image-digest: auth-check ## Print just the digest-pinned image reference (scriptable)
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@digest=$$(gcloud artifacts docker images describe "$(IMAGE_REPO):$(IMAGE_TAG)" \
	    --project $(PROJECT) --format='value(image_summary.digest)' 2>/dev/null); \
	  if [ -z "$$digest" ]; then \
	    digest=$$(gcloud artifacts docker images describe "$(IMAGE_REPO):latest" \
	      --project $(PROJECT) --format='value(image_summary.digest)' 2>/dev/null); \
	    if [ -n "$$digest" ]; then \
	      echo "warning: no image tagged $(IMAGE_TAG) (the current git SHA); using :latest." >&2; \
	      echo "         Run 'make deploy ENV=$(ENV)' to build and deploy at this commit." >&2; \
	    fi; \
	  fi; \
	  if [ -z "$$digest" ]; then \
	    echo "no image found at $(IMAGE_REPO):$(IMAGE_TAG) or :latest." >&2; \
	    echo "Build one first:  make build ENV=$(ENV)" >&2; \
	    exit 1; \
	  fi; \
	  echo "$(IMAGE_REPO)@$$digest"

# -- terraform ---------------------------------------------------------------
# Every terraform target depends on this.
#
# Cloud Shell does not ship terraform — it ships a stub that prints install
# instructions and can exit ZERO. `terraform init && terraform apply` then
# "succeeds" having created nothing, make prints its success message, and the
# first symptom is a NOT_FOUND from Secret Manager several steps later.
# "On PATH" is not the test; "reports a version" is.
tf-check: ## Verify terraform is real and new enough
	@scripts/require-terraform.sh

install-terraform: ## Install terraform into ~/bin, where a Cloud Shell session keeps it
	@scripts/install-terraform.sh

# Always -reconfigure. The backend is supplied on the command line now, so
# re-running with a different PROJECT has to adopt that project's bucket
# rather than stopping with "Backend configuration changed" and suggesting
# -migrate-state, which would copy the old project's state into the new
# bucket and then plan against resources that are not there.
tf-init: tf-check ## terraform init for $(ENV) against $(STATE_BUCKET)
	@echo ">> $(ENV) -> gs://$(STATE_BUCKET) (prefix env/$(ENV))"
	cd $(TF_DIR) && terraform init -reconfigure $(TF_BACKEND)
	@echo ">> resources in state: $$(cd $(TF_DIR) && terraform state list 2>/dev/null | wc -l | tr -d ' ')"
	@echo "   0 is correct for a project you have not applied to yet."


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
# The build IDENTITY is here too, and has to be. `make build` submits as
# sa-<name_prefix>-build-1 rather than the Compute Engine default (which
# carries project Editor), so on a cold start the next step fails with:
#
#   NOT_FOUND: generic::not_found: Unknown service account
#
# That read as an auth problem with the human's own credentials, which it is
# not. Three grants come with it — logWriter, objectViewer on the source
# tarball, and writer on the registry — because a build with its own service
# account fails without them.
#
# The placeholder digest satisfies the pipeline module's "must be a digest"
# validation, which Terraform evaluates even for resources -target excludes.
# No Cloud Run job is created by this step.
# Breaks the first-deploy cycle: Terraform creates the Artifact Registry that
# `make build` needs to push to.
#
# Four targets, and each unblocks the next step:
#
#   images             what `make build` pushes to
#   snowflake_password the container you store the password into
#   lightcast_accessor ordering, not bootstrap: Cloud Run validates at CREATE
#                      time that a job's runtime identity can read the secrets
#                      it mounts, and nothing in the graph forces that grant
#                      to land before the job
#   build_writer       lets sa-<prefix>-build-1 push to the registry
#
# The build service account itself is NOT here: it is created by
# infra/gcloud/01-admin-identities.sh, along with its project-level grants.
#
# The placeholder digest satisfies the pipeline module's "must be a digest"
# validation, which Terraform evaluates even for resources -target excludes.
# No Cloud Run job is created by this step.
tf-bootstrap: tf-init ## First deploy only: create Artifact Registry + the secret container
	cd $(TF_DIR) && terraform apply $(TF_VARS) \
	  -target=module.platform.google_artifact_registry_repository.images \
	  -target=module.platform.google_secret_manager_secret.snowflake_password \
	  -target=module.platform.google_secret_manager_secret_iam_member.lightcast_accessor \
	  -target=module.platform.google_artifact_registry_repository_iam_member.build_writer \
	  -var='image_digest=bootstrap@sha256:0000000000000000000000000000000000000000000000000000000000000000'
	@echo ""
	@echo ">> Artifact Registry and the secret container exist, and the build"
	@echo "   identity can push to the registry."
	@echo "   Next:"
	@echo "     1. printf '%s' 'THE_PASSWORD' | gcloud secrets versions add $(SECRET_NAME) --data-file=- --project $(PROJECT)"
	@echo "     2. make build ENV=$(ENV)"

# requirements.txt is the release artifact's dependency tree; pyproject.toml's
# ranges are for development. Regenerate after changing dependencies.
#
# Compiled for the TARGET platform, not this laptop: resolving on
# darwin/arm64 picks different wheels (and can drop or add platform-specific
# transitive deps) from the linux/amd64 image Cloud Run actually runs.
lock: ## Regenerate requirements.txt from pyproject.toml (run after changing deps)
	uv pip compile pyproject.toml --python-version 3.12 \
	  --python-platform x86_64-unknown-linux-gnu -o requirements.txt
	@echo ">> requirements.txt regenerated — commit it with the pyproject change"

lock-check: ## Verify requirements.txt matches pyproject.toml (part of `make check`)
	@uv pip compile pyproject.toml --quiet --python-version 3.12 \
	  --python-platform x86_64-unknown-linux-gnu -o /tmp/owc-req-check.txt
	@# Compare the pins only: uv writes the -o path into a header comment, so
	@# a byte-for-byte diff always fails on the temp filename.
	@if ! diff -q <(grep -v '^#' requirements.txt) <(grep -v '^#' /tmp/owc-req-check.txt) >/dev/null 2>&1; then \
	  echo ""; \
	  echo "requirements.txt is stale — pyproject.toml has changed since it was compiled."; \
	  echo "The image would install a dependency tree nobody reviewed."; \
	  echo ""; \
	  echo "  make lock"; \
	  echo ""; \
	  diff <(grep -v '^#' requirements.txt) <(grep -v '^#' /tmp/owc-req-check.txt) | head -20; \
	  exit 1; \
	fi
	@echo ">> lock-check OK: requirements.txt matches pyproject.toml"

# The base image is pinned by digest in docker/Dockerfile so a rebuild of one
# commit cannot land on a different base. Upstream publishes security fixes
# under the same tag, so refresh this deliberately rather than never.
base-digest: ## Print the current digest for the Dockerfile's base image tag
	@tok=$$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/python:pull" \
	  | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])'); \
	  d=$$(curl -sI -H "Authorization: Bearer $$tok" \
	    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
	    "https://registry-1.docker.io/v2/library/python/manifests/3.12-slim-bookworm" \
	    | tr -d '\r' | awk -F': ' '/^[Dd]ocker-[Cc]ontent-[Dd]igest/{print $$2}'); \
	  cur=$$(awk -F'@' '/^FROM python/{print $$2}' docker/Dockerfile); \
	  echo "  Dockerfile : $$cur"; \
	  echo "  upstream   : $$d"; \
	  if [ "$$cur" = "$$d" ]; then echo "  OK: current"; \
	  else echo ""; echo "  Base image moved. To adopt it, replace the digest in docker/Dockerfile."; fi

tf-fmt: ## terraform fmt across all modules and envs
	terraform fmt -recursive infra/terraform

tf-validate: tf-check ## terraform validate for $(ENV)
	cd $(TF_DIR) && terraform init -backend=false >/dev/null && terraform validate


verify-separation: auth-check ## Check each identity can reach only what it should
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@scripts/verify-separation.sh $(PROJECT) $(NAME_PREFIX) $(REGION)

preflight: auth-check ## Check the Snowflake secret has a version before applying
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
# The shell variables the docs' raw gcloud/bq commands use.
#
# Printed rather than documented as literals because this document is run
# TWICE — once per environment — and a hardcoded project id has to be
# hand-substituted on the second pass, in every command, with production on
# the other end. One missed substitution aims a command at dev while you
# believe you are in prod.
#
# Derived from tfvars, never typed: an empty PREFIX silently builds names
# like "gcs--raw-1" that 404 with no hint as to why, which is exactly how
# the old step 7 checks passed while testing nothing.
env-exports: ## Print the shell exports the docs' raw gcloud/bq commands use
	@test -n "$(PROJECT)"     || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@test -n "$(NAME_PREFIX)" || { echo "could not read name_prefix from $(TFVARS)" >&2; exit 1; }
	@echo "export ENV=$(ENV)"
	@echo "export PROJECT=$(PROJECT)"
	@echo "export PREFIX=$(NAME_PREFIX)"
	@echo "export REGION=$(REGION)"

tf-output: ## Show terraform outputs for $(ENV). Add NAME=<output> for one value.
	@scripts/tf-output.sh $(TF_DIR) $(ENV) $(PROJECT) $(NAME)



# -- the gcloud-only path ----------------------------------------------------
#
# OMES will not grant the Terraform process projectIamAdmin or
# serviceAccountAdmin, and cannot federate a personal GitHub account into
# their projects. So identities, project-level IAM and API enablement are
# created ONCE, by hand, with an account that does hold those roles; and
# every run after that is resources only.
#
# These four targets are that split. `make up ENV=dev` is the whole
# unprivileged half.

# Mirror this repository into the project.
#
# Cloning from GitHub is the normal way in; this covers whoever has GCP access
# but cannot clone. docs/deploy.md has the one-line fetch.
#
# .git is INCLUDED on purpose: without it `git rev-parse --short HEAD` has no
# answer, so `make build` tags the image "untracked" and `make which-image`
# can no longer tell you which commit a job is running.
#
# .env is EXCLUDED on purpose, and the check below is not a formality: it
# holds the Snowflake password, and a bucket is a much easier thing to read
# than a laptop.
source-push: auth-check ## Mirror this repo to gs://$(SOURCE_BUCKET) for anyone who cannot clone from GitHub
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@gcloud storage buckets describe gs://$(SOURCE_BUCKET) --project $(PROJECT) >/dev/null 2>&1 || { \
	  echo ""; \
	  echo "  gs://$(SOURCE_BUCKET) does not exist."; \
	  echo "  It is created by the one-time privileged step:"; \
	  echo ""; \
	  echo "    make gcloud-admin ENV=$(ENV)"; \
	  echo ""; exit 1; \
	}
	@sha=$$(git rev-parse --short HEAD 2>/dev/null || echo untracked); \
	  tmp=$$(mktemp -d); tarball="$$tmp/owc-okwire-pipeline-$$sha.tar.gz"; \
	  tar czf "$$tarball" \
	    --exclude='./.venv' --exclude='./.terraform' --exclude='*/.terraform' \
	    --exclude='./.mypy_cache' --exclude='./.pytest_cache' --exclude='./.ruff_cache' \
	    --exclude='./exports' --exclude='./.owcdata-local' \
	    --exclude='./.env' --exclude='*.tfstate' --exclude='*.tfstate.backup' \
	    -C . . ; \
	  if tar tzf "$$tarball" | grep -qE '(^|/)\.env$$'; then \
	    echo "REFUSING: .env is in the tarball — it holds the Snowflake password." >&2; \
	    rm -rf "$$tmp"; exit 1; \
	  fi; \
	  files=$$(tar tzf "$$tarball" | wc -l | tr -d ' '); \
	  size=$$(du -h "$$tarball" | awk '{print $$1}'); \
	  echo ">> $$files files, $$size, at commit $$sha"; \
	  gcloud storage cp "$$tarball" gs://$(SOURCE_BUCKET)/ --project $(PROJECT); \
	  gcloud storage cp "$$tarball" gs://$(SOURCE_BUCKET)/latest.tar.gz --project $(PROJECT); \
	  rm -rf "$$tmp"; \
	  echo ""; \
	  echo ">> mirrored. To fetch it without cloning from GitHub:"; \
	  echo ""; \
	  echo "     mkdir -p ~/owc && cd ~/owc \\"; \
	  echo "       && gcloud storage cat gs://$(SOURCE_BUCKET)/latest.tar.gz | tar xz"; \
	  echo ""

# The first thing to run on a project you did not create. Read-only, and it
# asks the IAM API what YOU can do rather than reading the project policy,
# which on someone else's project you will not be allowed to do.
access-check: auth-check ## Where do I stand on $(PROJECT), and what must I ask for?
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	infra/gcloud/00-access-check.sh $(PROJECT) $(NAME_PREFIX)

# The artifact you send whoever holds the admin roles. Self-contained: they
# do not need this repo, make, or terraform — just the commands and the
# context for why they are being asked.
omes-request: ## What to ask your project admin for, scoped to what is missing
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@infra/gcloud/03-admin-request.sh $(PROJECT) --prefix $(NAME_PREFIX) \
	  --principal $(TF_PRINCIPAL)

# Everything the deploy account can already do: enabling APIs, provisioning
# the Data Transfer agent, creating the two buckets. Doing this yourself
# before the call keeps it out of what you have to ask an admin for, and
# leaves their file containing nothing but identity work.
prep: auth-check ## Do the setup that needs no elevated rights (APIs, buckets)
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@tmp=$$(mktemp); \
	  infra/gcloud/04-standalone.sh $(PROJECT) --prefix $(NAME_PREFIX) \
	    --principal $(TF_PRINCIPAL) --location $(call tfvar,location) \
	    --part operator > "$$tmp"; \
	  gcloud config set project $(PROJECT) >/dev/null 2>&1; \
	  bash "$$tmp"; rc=$$?; rm -f "$$tmp"; exit $$rc

# A single file to hand a project admin who will not grant you the roles and
# will not clone your repo. Identity work only — the parts you can do
# yourself are in `make prep`, so nothing in their file needs explaining.
omes-script: ## Write a standalone setup script for your project admin to run
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@infra/gcloud/04-standalone.sh $(PROJECT) --prefix $(NAME_PREFIX) \
	  --principal $(TF_PRINCIPAL) --location $(call tfvar,location) --part admin

gcloud-admin-dry-run: ## Print every privileged command the one-time setup would run, and change nothing
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	infra/gcloud/01-admin-identities.sh $(PROJECT) --prefix $(NAME_PREFIX) \
	  --principal $(TF_PRINCIPAL) --dry-run

gcloud-admin: auth-check ## ONE TIME, PRIVILEGED: create the identities, project IAM and APIs
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	infra/gcloud/01-admin-identities.sh $(PROJECT) --prefix $(NAME_PREFIX) \
	  --principal $(TF_PRINCIPAL)

# An apply that works as you says nothing about an apply that runs with the
# reduced role set. This checks both halves, and also asserts the roles that
# must be ABSENT — the claim OMES actually asked us to make.
# STRICT=1 turns "the principal holds more than it needs" from a warning into
# a failure. Off by default because `make up` runs this first, and refusing to
# deploy because someone holds too MUCH permission helps nobody — the deploy
# would work. On for the audit you hand OMES.
iam-check: auth-check ## Verify the one-time setup landed. STRICT=1 also fails on excess privilege.
	@test -n "$(PROJECT)"     || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@test -n "$(NAME_PREFIX)" || { echo "could not read name_prefix from $(TFVARS)" >&2; exit 1; }
	infra/gcloud/02-verify-admin.sh $(PROJECT) --prefix $(NAME_PREFIX) \
	  --principal $(TF_PRINCIPAL) $(if $(STRICT),--strict,)

# The OMES naming convention is spelled out in three places: the Terraform
# modules' naming.tf, this Makefile, and infra/gcloud/names.sh. The third
# copy exists because those scripts run before Terraform is initialised, by
# people who may not have Terraform at all — but a copy that can drift is a
# copy that will.
names-check: ## Verify infra/gcloud/names.sh agrees with the Terraform naming convention
	@tf=$$(grep -oE 'sa_[a-z]+ *= *"\$$\{local\.abbrev\.sa\}-\$$\{var\.name_prefix\}-[a-z]+-1"' \
	    infra/terraform/modules/platform/naming.tf \
	  | sed -E 's/.*-\$$\{var\.name_prefix\}-([a-z]+)-1"/\1/' | sort -u); \
	  sh=$$(PROJECT=x PREFIX=y bash -c 'source infra/gcloud/names.sh; for e in "$${ALL_SAS[@]}"; do echo "$${e}"; done' \
	  | sed -E 's/^sa-y-([a-z]+)-1@.*/\1/' | sort -u); \
	  if [ "$$tf" = "$$sh" ]; then \
	    echo ">> names-check OK: $$(echo $$tf | wc -w | tr -d ' ') service account names agree"; \
	  else \
	    echo ""; \
	    echo "  infra/gcloud/names.sh and modules/platform/naming.tf disagree."; \
	    echo ""; \
	    diff <(echo "$$tf") <(echo "$$sh") | sed 's/^/    /'; \
	    echo ""; \
	    echo "  < only in naming.tf (Terraform)   > only in names.sh (gcloud)"; \
	    echo ""; exit 1; \
	  fi

smoke: auth-check ## One real end-to-end run of each pipeline, then show the manifest
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@echo ">> lightcast / dim_area  (78 rows; unlimited, so it really publishes)"
	gcloud run jobs execute $(LIGHTCAST_JOB) --region $(REGION) --project $(PROJECT) \
	  --args="run,lightcast,--dataset,dim_area" --tasks=1 --wait
	@echo ""
	@echo ">> enrollment"
	gcloud run jobs execute $(ENROLLMENT_JOB) --region $(REGION) --project $(PROJECT) --wait
	@echo ""
	@echo ">> run manifest"
	@# The query is ONE line on purpose. A backslash continuation inside a
	@# single-quoted string is not a continuation to the shell — the quotes
	@# make it literal — and GNU make 3.81 and 4.3 disagree about whether they
	@# collapse it first. It worked on macOS (3.81) and failed in Cloud Shell
	@# (4.3) with: Syntax error: Expected end of input but got "\" at [1:80].
	@bq query --project_id=$(PROJECT) --use_legacy_sql=false --format=pretty \
	  'SELECT pipeline, dataset, status, row_count, ROUND(duration_seconds,1) AS secs FROM `owc_ops.pipeline_runs` ORDER BY started_at DESC LIMIT 10'

# The whole unprivileged half, in order, from a fresh clone.
#
# Stops at the Snowflake password rather than prompting for it: the value must
# not reach a shell history, a Makefile, or Terraform state. Re-run `make up`
# after storing it and everything before that point is a no-op.
up: ## Stand $(ENV) up end to end, after gcloud-admin has run once
	@$(MAKE) --no-print-directory iam-check ENV=$(ENV)
	@echo ""
	@$(MAKE) --no-print-directory tf-init ENV=$(ENV)
	@echo ""
	@$(MAKE) --no-print-directory tf-bootstrap ENV=$(ENV)
	@echo ""
	@versions=$$(gcloud secrets versions list $(SECRET_NAME) --project $(PROJECT) \
	    --filter='state:ENABLED' --format='value(name)' 2>/dev/null | wc -l | tr -d ' '); \
	  if [ "$$versions" = "0" ]; then \
	    echo ""; \
	    echo "  Stopping here: $(SECRET_NAME) has no version yet."; \
	    echo ""; \
	    echo "  The lightcast job reads SNOWFLAKE_PASSWORD from versions/latest at"; \
	    echo "  CREATION time, so the apply below cannot succeed without one."; \
	    echo "  Store it, then run 'make up ENV=$(ENV)' AGAIN — everything above"; \
	    echo "  this point is a no-op the second time:"; \
	    echo ""; \
	    echo "    printf '%s' 'THE_PASSWORD' | \\"; \
	    echo "      gcloud secrets versions add $(SECRET_NAME) --data-file=- --project $(PROJECT)"; \
	    echo ""; exit 1; \
	  fi
	@$(MAKE) --no-print-directory build ENV=$(ENV)
	@image=$$($(MAKE) -s --no-print-directory image-digest ENV=$(ENV)) && \
	  $(MAKE) --no-print-directory tf-apply ENV=$(ENV) TF_ARGS="-var=image_digest=$$image"
	@$(MAKE) --no-print-directory set-image ENV=$(ENV)
	@echo ""
	@$(MAKE) --no-print-directory verify-separation ENV=$(ENV)
	@echo ""
	@echo ">> $(ENV) is up. Prove it end to end:  make smoke ENV=$(ENV)"

tf-plan: tf-init ## terraform plan for $(ENV). Add TF_ARGS='-var=image_digest=...'
	cd $(TF_DIR) && terraform plan $(TF_VARS) $(TF_ARGS)

tf-apply: tf-init preflight ## terraform apply for $(ENV). Add TF_ARGS='-var=image_digest=...'
	cd $(TF_DIR) && terraform apply $(TF_VARS) $(TF_ARGS)

clean: ## Remove caches and local pipeline output
	rm -rf .mypy_cache .ruff_cache .pytest_cache exports .owcdata-local
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
