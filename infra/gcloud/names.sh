# ---------------------------------------------------------------------------
# Resource names, derived from one prefix. Sourced, not executed.
#
# This is the THIRD place the OMES naming convention
# `<type>-<project-prefix>-<qualifier>-<seq>` is spelled out, after
# infra/terraform/modules/*/naming.tf and the Makefile. It is duplicated
# rather than read from Terraform on purpose: these scripts run BEFORE
# Terraform has ever been initialised in a project, and often by someone
# (OMES) who has gcloud but not terraform. A name that has to be resolved by
# the tool you are trying to bootstrap is not a bootstrap.
#
# `make names-check` diffs these against naming.tf so the duplication cannot
# silently drift.
# ---------------------------------------------------------------------------

# Requires PROJECT and PREFIX to already be set.
: "${PROJECT:?names.sh needs PROJECT}"
: "${PREFIX:?names.sh needs PREFIX}"

sa_email() { printf 'sa-%s-%s-1@%s.iam.gserviceaccount.com' "$PREFIX" "$1" "$PROJECT"; }

SA_LIGHTCAST=$(sa_email lightcast)
SA_ENROLLMENT=$(sa_email enrollment)
SA_SCHEDULER=$(sa_email scheduler)
SA_BUILD=$(sa_email build)
SA_POWERBI=$(sa_email powerbi)
SA_FRESHNESS=$(sa_email freshness)

# Every identity Terraform ATTACHES to a resource. The Terraform principal
# needs iam.serviceAccountUser on each of these and nothing else — attaching
# a service account to a Cloud Run job, a Scheduler job, a Cloud Build
# submission or a BigQuery scheduled query requires actAs on it.
#
# powerbi is deliberately absent: nothing attaches it. Its key is minted by
# hand (ADR-006) and it is never set on a resource.
ATTACHED_SAS=("$SA_LIGHTCAST" "$SA_ENROLLMENT" "$SA_SCHEDULER" "$SA_BUILD" "$SA_FRESHNESS")

# All six, for existence checks.
ALL_SAS=("${ATTACHED_SAS[@]}" "$SA_POWERBI")

# The identity that RUNS the deploy, as opposed to the six the deploy
# creates. Deliberately outside ALL_SAS and ATTACHED_SAS: nothing attaches it
# to a resource, Terraform never sees it, and `make names-check` compares
# ALL_SAS against the Terraform naming convention — which does not and should
# not know about it.
#
# It exists so that no human holds resource-admin roles. It carries them all;
# a named person is granted roles/iam.serviceAccountTokenCreator on this one
# account and impersonates it to deploy. That is auditable (every action is
# attributable to the person who minted the token), revocable with one
# binding, and satisfies OMES's rule that an operator hold no admin-level
# role. See docs/deploy.md#deploy-identity.
SA_DEPLOY=$(sa_email deploy)

BUCKET_RAW="gcs-${PREFIX}-raw-1"
BUCKET_ENROLLMENT_STATE="gcs-${PREFIX}-enrollment-state-1"
BUCKET_STATE="gcs-${PROJECT}-tfstate-1"

# A mirror of this repository inside the project.
#
# Cloning from GitHub is the normal way in and needs nothing here. This serves
# the case that has no clone available: someone with access to the GCP project
# but not to the repo, or a Cloud Shell that cannot authenticate to GitHub.
# `make source-push` publishes a tarball; docs/deploy.md has the
# one-line fetch.
#
# Created by 01-admin-identities.sh rather than by Terraform, for the same
# reason the state bucket is: a `terraform destroy` on a scratch dev
# environment must not be able to take the mirror with it.
BUCKET_SOURCE="gcs-${PREFIX}-source-1"

SECRET_SNOWFLAKE="sm-${PREFIX}-snowflake-password-1"
REGISTRY_IMAGES="ar-${PREFIX}-images-1"

JOB_LIGHTCAST="cr-${PREFIX}-lightcast-1"
JOB_ENROLLMENT="cr-${PREFIX}-enrollment-1"

# ---------------------------------------------------------------------------
# The two role sets that this whole split exists to separate.
# ---------------------------------------------------------------------------

# What the Terraform principal needs, once identities are out of Terraform.
#
# Every entry administers a RESOURCE this repo creates. None of them can read
# or write the project IAM policy, and none can create, modify or delete a
# service account. That is the property OMES asked for, and
# 02-verify-admin.sh asserts it rather than trusting this comment.
TF_PRINCIPAL_ROLES=(
  # services.use only. NOT serviceUsageAdmin: the APIs are enabled here, in
  # step 1, so Terraform never enables one.
  roles/serviceusage.serviceUsageConsumer
  # The two buckets and their own bucket-level policies.
  roles/storage.admin
  # Datasets, tables, views, and the freshness scheduled query (a Data
  # Transfer Service resource).
  roles/bigquery.admin
  # run.ADMIN, not run.developer. modules/pipeline/job.tf grants the scheduler
  # run.developer on each job, and writing that binding needs
  # run.jobs.setIamPolicy — which run.developer does not carry and run.admin
  # does. With run.developer here the apply dies on that one resource and the
  # schedulers 403 forever. Confirm with:
  #   gcloud iam roles describe roles/run.admin
  # This is the one role in this list that is broader than "administer the
  # resource". It is acceptable because it is held by SA_DEPLOY, which no
  # human logs in as — it would not be acceptable on a person's account.
  roles/run.admin
  roles/cloudscheduler.admin
  # The secret CONTAINER. The value is added by hand and never enters state.
  roles/secretmanager.admin
  roles/artifactregistry.admin
  # Notification channels and alert policies.
  roles/monitoring.editor
  # Log-based metrics.
  roles/logging.configWriter
  # Reading them back. configWriter creates metrics and sinks; it does not
  # grant logging.logEntries.list. Without this the runbook's diagnostics do
  # not run at all — every structured-log lookup, the scheduler's execution
  # history, and the failure detail behind every alert. The alerting in this
  # system is log-based, so an operator who cannot read logs cannot work.
  roles/logging.viewer
  # `make build` submits a Cloud Build. Drop this if builds move to OMES CI.
  roles/cloudbuild.builds.editor
)

# The roles this split REMOVES, which 02-verify-admin.sh asserts are absent.
#
# These are the four Stephen Jones named, or their direct consequences:
#   projectIamAdmin          every google_project_iam_member read-modify-wrote
#                            the project IAM policy, so all 24 of them needed
#                            getIamPolicy just to refresh
#   serviceAccountAdmin      Terraform created seven service accounts
#   workloadIdentityPoolAdmin  the GitHub WIF pool, now not built at all
#   serviceUsageAdmin        Terraform enabled fourteen APIs
TF_PRINCIPAL_FORBIDDEN_ROLES=(
  roles/resourcemanager.projectIamAdmin
  roles/iam.serviceAccountAdmin
  roles/iam.workloadIdentityPoolAdmin
  roles/serviceusage.serviceUsageAdmin
  roles/owner
  roles/editor
)

# Project-level grants for the runtime identities, "<sa-key>|<role>".
#
# Scheduler is absent on purpose: it holds run.developer on the two jobs
# specifically, which is resource-scoped and stays in Terraform. Not
# run.invoker — the schedulers post an overrides body. See job.tf.
RUNTIME_PROJECT_GRANTS=(
  "lightcast|roles/bigquery.jobUser"
  "lightcast|roles/logging.logWriter"
  "lightcast|roles/monitoring.metricWriter"
  "enrollment|roles/bigquery.jobUser"
  "enrollment|roles/logging.logWriter"
  "enrollment|roles/monitoring.metricWriter"
  # Required when a build specifies its own service account.
  "build|roles/logging.logWriter"
  # Reads the source tarball from gs://<project>_cloudbuild, which
  # `gcloud builds submit` creates itself — so a bucket-scoped grant cannot
  # exist before the first build.
  "build|roles/storage.objectViewer"
  "powerbi|roles/bigquery.jobUser"
  "freshness|roles/bigquery.jobUser"
)

# The 16 APIs. cloudresourcemanager and serviceusage come first and are the
# chicken-and-egg pair: nothing else can be enabled without them.
REQUIRED_APIS=(
  cloudresourcemanager.googleapis.com
  serviceusage.googleapis.com
  run.googleapis.com
  cloudscheduler.googleapis.com
  artifactregistry.googleapis.com
  cloudbuild.googleapis.com
  storage.googleapis.com
  bigquery.googleapis.com
  bigquerystorage.googleapis.com
  bigquerydatatransfer.googleapis.com
  secretmanager.googleapis.com
  logging.googleapis.com
  monitoring.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  sts.googleapis.com
)
