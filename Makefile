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
# and glues onto the value. `enable_wif = false  # no pool` parsed as
# "false#nopool", which is not "false", so every guard reading it took the
# wrong branch silently.
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
NAME_PREFIX ?= $(call tfvar,name_prefix)
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
# The identity GitHub Actions assumes via WIF. Mirrors modules/wif/main.tf,
# which is also the source `deployer-check` reads the expected roles from.
DEPLOYER_SA = sa-$(NAME_PREFIX)-deployer-1@$(PROJECT).iam.gserviceaccount.com
# A mirror of this repo inside the project, for anyone who cannot clone from
# GitHub. Created by infra/gcloud/01-admin-identities.sh, not by Terraform.
SOURCE_BUCKET = gcs-$(NAME_PREFIX)-source-1
WIF_TF     := infra/terraform/modules/wif/main.tf
# Whether this environment builds the GitHub WIF path at all. False in both
# environments: OMES cannot federate a personal GitHub account. The targets
# that only make sense with Actions read this and refuse rather than
# reporting a missing deployer as a permission problem.
ENABLE_WIF  = $(call tfvar,enable_wif)
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
        diff-enrollment derive-scrape derive-check lock lock-check docs-check base-digest build deploy set-image which-image image-digest tf-init tf-reinit tf-bootstrap preflight wif-check deployer-check verify-separation env-exports tf-output gh-vars tf-plan tf-apply tf-fmt tf-validate clean \
        gcloud-admin gcloud-admin-dry-run iam-check names-check smoke up source-push

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
docs-check: ## Verify the docs only reference targets, outputs and scripts that exist
	@python3 scripts/docs-check.py

check: lint typecheck derive-check lock-check docs-check validate test ## Everything CI runs on a PR

diff-enrollment: ## Show every change made to the carried-over enrollment script
	@diff -u $(ORIGINAL) $(SCRAPE) || true

derive-scrape: ## Regenerate scrape.py from the pristine original
	$(PY) scripts/derive_scrape.py

derive-check: ## Verify scrape.py matches its derivation (CI runs this)
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
set-image: auth-check ## Point both Cloud Run jobs at a digest (default: the newest build)
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@image="$(if $(IMAGE),$(IMAGE),$$($(MAKE) -s --no-print-directory image-digest ENV=$(ENV)))"; \
	  case "$$image" in *@sha256:*) ;; *) echo "refusing a non-digest image: $$image" >&2; exit 1;; esac; \
	  for job in $(LIGHTCAST_JOB) $(ENROLLMENT_JOB); do \
	    echo ">> $$job -> $$image"; \
	    gcloud run jobs update "$$job" --image "$$image" \
	      --region $(REGION) --project $(PROJECT) --quiet >/dev/null; \
	  done; \
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
tf-init: ## terraform init for $(ENV)
	cd $(TF_DIR) && terraform init

# Re-point a working copy at a different project's state bucket.
#
# terraform caches the backend config in .terraform/, so after editing
# backend.tf every command stops with "Backend configuration changed" and
# suggests `-migrate-state` FIRST. That suggestion is wrong here and it is
# destructive in a quiet way: migrating copies the OLD project's state into
# the NEW bucket, after which Terraform believes the old project's resources
# exist in the new one and plans against them.
#
# Each environment's state already lives in its own bucket. Switching
# projects means adopting that bucket as-is, which is -reconfigure. The old
# state is left untouched where it is.
#
# A fresh clone never needs this — there is no cache to invalidate.
tf-reinit: ## Re-point $(ENV) at the bucket in its backend.tf (after changing projects)
	@echo ">> re-pointing $(ENV) at $$(awk -F'"' '/bucket/{print $$2}' $(TF_DIR)/backend.tf)"
	cd $(TF_DIR) && terraform init -reconfigure
	@echo ""
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
tf-bootstrap: ## First deploy only: create Artifact Registry + the secret container
	cd $(TF_DIR) && terraform init && terraform apply \
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

lock-check: ## Verify requirements.txt matches pyproject.toml (CI runs this)
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
	@# One shell, not two. `exit 0` inside its own recipe line ends only that
	@# line's subshell — make then runs the next line regardless, which had
	@# this printing "skipped" and then doing the check anyway.
	@if [ "$(ENABLE_WIF)" != "true" ]; then \
	  echo ">> wif-check skipped: enable_wif = false in $(TFVARS)"; \
	  echo "   No WIF pool and no deployer service account are built, so there is"; \
	  echo "   no attribute_condition for github_repository to have to match."; \
	  exit 0; \
	fi; \
	remote=$$(git remote get-url origin 2>/dev/null \
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

verify-separation: auth-check ## Check each identity can reach only what it should
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@scripts/verify-separation.sh $(PROJECT) $(NAME_PREFIX)

preflight: auth-check wif-check ## Check the Snowflake secret has a version before applying
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

# Deploying by hand runs as YOUR credentials; GitHub Actions runs as the
# deployer service account. Those are different identities with different
# permissions, so "the apply worked on my laptop" says nothing about whether
# CI can run the same apply. That gap is invisible until a push fails.
#
# It bites hardest on the two roles that are about administering IAM itself
# rather than a resource — projectIamAdmin and workloadIdentityPoolAdmin —
# because every google_project_iam_member needs getIamPolicy to refresh, and
# serviceAccountAdmin grants no workloadIdentityPools permissions at all. A
# CI run missing either dies at refresh with a 403 and a wall of identical
# errors that name the role being granted, not the role that is missing.
#
# The expected list is parsed out of modules/wif/main.tf rather than repeated
# here, so adding a role to that module cannot leave this check behind. Only
# google_project_iam_member blocks are read: the artifact-registry and
# service-account grants in that file are not project-level and would never
# appear in a project IAM policy.
# No auth-check prerequisite: whether this environment HAS a deployer is a
# configuration question, and answering it with "your gcloud token expired"
# sends you to re-authenticate for a check that was never going to run.
deployer-check: ## Verify the deployer SA has every role GitHub Actions needs
	@if [ "$(ENABLE_WIF)" != "true" ]; then \
	  echo ""; \
	  echo "  enable_wif = false in $(TFVARS), so there is no deployer service"; \
	  echo "  account to check. GitHub Actions is not the deploy path for this"; \
	  echo "  environment — deploys run from gcloud, as you."; \
	  echo ""; \
	  echo "  What to check instead:  make iam-check ENV=$(ENV)"; \
	  echo ""; exit 1; \
	fi
	@scripts/require-gcloud-auth.sh
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@expected=$$(awk '/^resource "google_project_iam_member"/,/^\}$$/' $(WIF_TF) \
	    | grep -oE '"roles/[A-Za-z.]+"' | tr -d '"' | sort -u); \
	  test -n "$$expected" || { echo "could not parse any roles from $(WIF_TF)" >&2; exit 1; }; \
	  actual=$$(gcloud projects get-iam-policy $(PROJECT) \
	    --flatten="bindings[].members" \
	    --filter="bindings.members:$(DEPLOYER_SA)" \
	    --format="value(bindings.role)" 2>/dev/null | sort -u); \
	  if [ -z "$$actual" ]; then \
	    echo ""; \
	    echo "  $(DEPLOYER_SA)"; \
	    echo "  has no roles on $(PROJECT) — or it does not exist yet."; \
	    echo ""; \
	    echo "  Run the apply that creates it:  make tf-apply ENV=$(ENV)"; \
	    echo ""; exit 1; \
	  fi; \
	  missing=$$(comm -23 <(echo "$$expected") <(echo "$$actual")); \
	  if [ -n "$$missing" ]; then \
	    echo ""; \
	    echo "  $(DEPLOYER_SA) is missing $$(echo "$$missing" | wc -l | tr -d ' ') role(s):"; \
	    echo ""; \
	    echo "$$missing" | sed 's/^/    /'; \
	    echo ""; \
	    echo "  GitHub Actions will fail at terraform refresh with a 403. Your own"; \
	    echo "  applies keep working, because they run as you and not as this SA."; \
	    echo ""; \
	    echo "  Fix — apply as a project owner, which creates the bindings:"; \
	    echo "    make tf-apply ENV=$(ENV) TF_ARGS=\"-var=image_digest=\$$(make -s image-digest ENV=$(ENV))\""; \
	    echo ""; exit 1; \
	  fi; \
	  echo ">> deployer-check OK: $(DEPLOYER_SA) has all $$(echo "$$expected" | wc -l | tr -d ' ') project roles"
	@# Project roles are only half of it. Attaching a service account to a
	@# resource needs iam.serviceAccounts.actAs ON THAT ACCOUNT, which is a
	@# per-SA binding and invisible to the project-role check above. A human
	@# applying as owner has actAs on everything, so a missing grant here is
	@# a CI-only 403 — and for the freshness SA, a PROD-only one, since dev
	@# does not create that resource at all.
	@wanted=$$(awk '/impersonatable_service_accounts = \[/,/^  \]/' $(TF_DIR)/main.tf 	    | grep -oE 'service_account_emails\.[a-z]+' | cut -d. -f2 | sort -u); 	  test -n "$$wanted" || { echo "could not parse impersonatable_service_accounts from $(TF_DIR)/main.tf" >&2; exit 1; }; 	  missing=""; 	  for n in $$wanted; do 	    email="sa-$(NAME_PREFIX)-$$n-1@$(PROJECT).iam.gserviceaccount.com"; 	    if ! gcloud iam service-accounts get-iam-policy "$$email" --project $(PROJECT) 	         --flatten='bindings[].members' 	         --filter="bindings.members:$(DEPLOYER_SA) AND bindings.role:roles/iam.serviceAccountUser" 	         --format='value(bindings.role)' 2>/dev/null | grep -q serviceAccountUser; then 	      missing="$$missing $$n"; 	    fi; 	  done; 	  if [ -n "$$missing" ]; then 	    echo ""; 	    echo "  $(DEPLOYER_SA) cannot actAs:$$missing"; 	    echo ""; 	    echo "  Terraform attaches these service accounts to resources, which needs"; 	    echo "  iam.serviceAccountUser on each. CI fails with:"; 	    echo "    Error 403: The principal ... lacks IAM permission \"iam.serviceAccounts.actAs\""; 	    echo "  Your own applies keep working — as owner you have actAs on everything."; 	    echo ""; 	    echo "  Fix — apply as a project owner:  make tf-apply ENV=$(ENV)"; 	    echo ""; exit 1; 	  fi; 	  echo ">> deployer-check OK: and can actAs $$(echo $$wanted | wc -w | tr -d ' ') service account(s):$$(echo $$wanted | tr '\n' ' ' | sed 's/^/ /')"

# Sets the three per-environment GitHub repository variables in one step.
#
# Doing this by hand is a trap: `gh variable set --body "$$(...)"` does NOT
# abort when the inner command fails — it passes an empty string, and gh then
# drops into an interactive "Paste your variable" prompt. Pressing enter sets
# the variable to empty, which fails later at the auth step with nothing
# pointing at the cause. This resolves every value first and only then writes.
#
# deployer-check runs first for the same reason tf-apply runs preflight: this
# is the moment you hand deploys over to CI, so it is the last moment the
# permission gap is cheap to find.
gh-vars: deployer-check ## Set the GitHub repo variables for $(ENV) from its terraform outputs
	@command -v gh >/dev/null || { echo "gh CLI not installed: https://cli.github.com" >&2; exit 1; }
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@up=$$(echo $(ENV) | tr a-z A-Z); \
	  wif=$$($(MAKE) -s --no-print-directory tf-output ENV=$(ENV) NAME=workload_identity_provider) || exit 1; \
	  sa=$$($(MAKE)  -s --no-print-directory tf-output ENV=$(ENV) NAME=deployer_service_account)  || exit 1; \
	  test -n "$$wif" && test -n "$$sa" || { echo "refusing to set an empty variable" >&2; exit 1; }; \
	  case "$$wif" in projects/*/locations/global/workloadIdentityPools/*/providers/*) ;; \
	    *) echo "" >&2; echo "workload_identity_provider does not look like a provider path:" >&2; \
	       echo "  $$wif" >&2; echo "" >&2; \
	       echo "terraform output prints 'Warning: No outputs found' and exits ZERO when the" >&2; \
	       echo "state has no outputs, so a non-empty check is not enough. Apply this" >&2; \
	       echo "environment first: make tf-apply ENV=$(ENV)" >&2; echo "" >&2; exit 1 ;; esac; \
	  case "$$sa" in *@*.iam.gserviceaccount.com) ;; \
	    *) echo "" >&2; echo "deployer_service_account does not look like an SA email:" >&2; \
	       echo "  $$sa" >&2; echo "" >&2; exit 1 ;; esac; \
	  test -n "$(NAME_PREFIX)" || { echo "could not read name_prefix from $(TFVARS)" >&2; exit 1; }; \
	  gh variable set REGION              --body "$(REGION)"; \
	  gh variable set PROJECT_ID_$$up     --body "$(PROJECT)"; \
	  gh variable set NAME_PREFIX_$$up    --body "$(NAME_PREFIX)"; \
	  gh variable set WIF_PROVIDER_$$up   --body "$$wif"; \
	  gh variable set DEPLOYER_SA_$$up    --body "$$sa"; \
	  echo ""; gh variable list

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
# but cannot clone. docs/09-gcloud-deploy.md has the one-line fetch.
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

gcloud-admin-dry-run: ## Print every privileged command the one-time setup would run, and change nothing
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	infra/gcloud/01-admin-identities.sh $(PROJECT) --prefix $(NAME_PREFIX) \
	  --principal $(TF_PRINCIPAL) --dry-run

gcloud-admin: auth-check ## ONE TIME, PRIVILEGED: create the identities, project IAM and APIs
	@test -n "$(PROJECT)" || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	infra/gcloud/01-admin-identities.sh $(PROJECT) --prefix $(NAME_PREFIX) \
	  --principal $(TF_PRINCIPAL)

# The replacement for `deployer-check` on this path.
#
# Same failure it always caught, one layer down: an apply that works as you
# says nothing about an apply that runs with the reduced role set. The
# difference is that it now also asserts the roles that must be ABSENT, which
# is the claim OMES actually asked us to make.
iam-check: auth-check ## Verify the one-time setup landed and Terraform's principal is correctly limited
	@test -n "$(PROJECT)"     || { echo "could not read project_id from $(TFVARS)" >&2; exit 1; }
	@test -n "$(NAME_PREFIX)" || { echo "could not read name_prefix from $(TFVARS)" >&2; exit 1; }
	infra/gcloud/02-verify-admin.sh $(PROJECT) --prefix $(NAME_PREFIX) --principal $(TF_PRINCIPAL)

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
	@bq query --project_id=$(PROJECT) --use_legacy_sql=false --format=pretty \
	  'SELECT pipeline, dataset, status, row_count, ROUND(duration_seconds,1) AS secs \
	   FROM `owc_ops.pipeline_runs` ORDER BY started_at DESC LIMIT 10'

# The whole unprivileged half, in order, from a fresh clone.
#
# Stops at the Snowflake password rather than prompting for it: the value must
# not reach a shell history, a Makefile, or Terraform state. Re-run `make up`
# after storing it and everything before that point is a no-op.
up: ## Stand $(ENV) up end to end, after gcloud-admin has run once
	@$(MAKE) --no-print-directory iam-check ENV=$(ENV)
	@echo ""
	@$(MAKE) --no-print-directory tf-reinit ENV=$(ENV)
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

tf-plan: ## terraform plan for $(ENV). Add TF_ARGS='-var=image_digest=...'
	cd $(TF_DIR) && terraform plan $(TF_ARGS)

tf-apply: preflight ## terraform apply for $(ENV). Add TF_ARGS='-var=image_digest=...'
	cd $(TF_DIR) && terraform apply $(TF_ARGS)

clean: ## Remove caches and local pipeline output
	rm -rf .mypy_cache .ruff_cache .pytest_cache exports .owcdata-local
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
