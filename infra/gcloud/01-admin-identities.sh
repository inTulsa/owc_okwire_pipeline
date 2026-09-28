#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The privileged half. Run ONCE per project, by someone who holds
# serviceAccountAdmin and projectIamAdmin. Nothing after this needs either.
#
# This exists because of a specific piece of OMES feedback:
#
#   "your terraform should not write IAM on each run ... projectIamAdmin and
#    serviceAccountAdmin is too much for terraform process, we should be able
#    to manual create the resources needed, and then use lower permissions on
#    the additional runs"
#
# So every identity, every project-level IAM binding, every API enable, and
# the state and source buckets are created here, in gcloud, once. Terraform
# is then left with resources only, and runs as a DEPLOY SERVICE ACCOUNT
# holding the resource-admin roles in TF_PRINCIPAL_ROLES (see names.sh) —
# no projectIamAdmin, no serviceAccountAdmin, no serviceUsageAdmin.
#
# --principal names the PERSON who will deploy. They get exactly one binding:
# tokenCreator on that deploy account, which they impersonate. No human ever
# holds a resource-admin role.
#
# Idempotent: safe to re-run, and re-running is how you repair a partial run.
#
#   ./infra/gcloud/01-admin-identities.sh owc-dpar-d --dry-run
#   ./infra/gcloud/01-admin-identities.sh owc-dpar-d \
#       --principal user:someone@agency.ok.gov
#
# --dry-run prints every gcloud command and changes nothing. Send that output
# to OMES if they would rather run the commands themselves than a script.
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT=""
PREFIX=""
PRINCIPAL=""
LOCATION="US"
DRY_RUN=0
SKIP_PRINCIPAL=0
# Skip roles/run.admin and use roles/run.developer. See the grant below.
NO_RUN_ADMIN=0
SKIP_STATE_BUCKET=0

usage() {
  cat >&2 <<USAGE
usage: $0 <project-id> [options]

  --prefix P          OMES name prefix (default: the project id)
  --principal P       WHO MAY DEPLOY, as a full IAM member string. Their only
                      binding is tokenCreator on the deploy service account,
                      which they impersonate — never a resource-admin role.
                        user:someone@agency.ok.gov
                        group:owc-deployers@agency.ok.gov
                      REQUIRED, and never defaulted: it used to fall back to
                      the active gcloud account, so an admin running this
                      named themselves and the operator got nothing.
                      A group is the better answer for more than one person.
  --no-principal      Create the deploy account and all its roles, but grant
                      no human the right to impersonate it. Use when the
                      deploying person is not decided yet; re-run with
                      --principal later to add them.
  --no-run-admin      Grant the deploy account roles/run.developer instead of
                      roles/run.admin. Only if your organization will not
                      allow run.admin — it means an admin must return once,
                      after the first deploy, to grant the scheduler its
                      binding on each job. The script tries run.admin and
                      falls back on its own, so this is rarely needed.
  --no-state-bucket   Skip the Terraform state bucket (OMES is hosting state).
  --location L        State bucket location (default US)
  --dry-run           Print every command; change nothing.
USAGE
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)          PREFIX="${2:?}"; shift 2 ;;
    --principal)       PRINCIPAL="${2:?}"; shift 2 ;;
    --no-principal)    SKIP_PRINCIPAL=1; shift ;;
    --no-run-admin)    NO_RUN_ADMIN=1; shift ;;
    --no-state-bucket) SKIP_STATE_BUCKET=1; shift ;;
    --location)        LOCATION="${2:?}"; shift 2 ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage ;;
    -*)                echo "unknown option: $1" >&2; usage ;;
    *)                 [[ -z "$PROJECT" ]] || { echo "unexpected argument: $1" >&2; usage; }
                       PROJECT="$1"; shift ;;
  esac
done

[[ -n "$PROJECT" ]] || usage
PREFIX="${PREFIX:-$PROJECT}"

# The service account id `sa-<prefix>-enrollment-1` spends 16 characters
# before the prefix, and GCP caps account_id at 30. Terraform validates this
# at plan time; this script runs first, so it has to validate it too or the
# failure is a 400 from the IAM API partway through creating six accounts.
if (( ${#PREFIX} > 14 )); then
  echo "prefix '$PREFIX' is ${#PREFIX} characters; the cap is 14 because it is" >&2
  echo "embedded in service account ids and 'sa-<prefix>-enrollment-1' already" >&2
  echo "spends 16 of the 30 GCP allows." >&2
  exit 1
fi

# shellcheck source=names.sh
source "$(dirname "${BASH_SOURCE[0]}")/names.sh"

# --request output gets pasted into mail and ticket systems, where escape
# codes arrive as literal garbage. Plain text there, colour everywhere else.
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  B=""; R=""; D=""
else
  B=$'\033[1m'; R=$'\033[0m'; D=$'\033[2m'
fi

say()  { printf '\n%s==> %s%s\n' "$B" "$*" "$R"; }
note() { printf '    %s\n' "$*"; }

# Echo then execute. Every mutation in this script goes through run(), so
# --dry-run is complete by construction rather than by remembering to guard
# each call.
#
# The echo is SHELL-QUOTED, which matters more than it looks: the point of
# --dry-run is to hand the commands to OMES to run themselves, and
# `--description Runs the lightcast Cloud Run job.` pasted into a terminal is
# six arguments, not one. Only arguments that need quoting get it, so the
# common case stays readable.
shellquote() {
  local arg out="" esc
  local sq="'"
  local esc_sq="'\\''"
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
      out+="$arg "
    else
      # Close the quote, emit an escaped ', reopen. The two helper
      # variables above hold those literals, because writing them inline
      # inside a ${x//a/b} inside a double-quoted string needs four levels
      # of escaping and gets it wrong quietly.
      esc=${arg//"$sq"/"$esc_sq"}
      out+="$sq$esc$sq "
    fi
  done
  printf '%s' "${out% }"
}

run() {
  printf '  %s$%s %s\n' "$D" "$R" "$(shellquote "$@")"
  (( DRY_RUN )) && return 0
  "$@"
}

if (( DRY_RUN )); then
  printf '\n%s*** DRY RUN — nothing below is executed ***%s\n' "$B" "$R"
fi

say "Project $PROJECT (prefix $PREFIX)"

if (( ! DRY_RUN )); then
  gcloud projects describe "$PROJECT" >/dev/null || {
    echo "Project not found, or you lack access. OMES provisions the project" >&2
    echo "and its spoke network separately; this script deploys into one that" >&2
    echo "already exists." >&2
    exit 1
  }
fi

# --principal is the PERSON who will deploy. It is never defaulted.
#
# It used to fall back to the active gcloud account, which meant an admin
# running this from their own shell silently granted themselves — that is
# exactly what happened on owc-dpar-d, and the operator got nothing. A
# default that is wrong most of the time is worse than a prompt.
if (( ! SKIP_PRINCIPAL )) && [[ -z "$PRINCIPAL" ]]; then
  cat >&2 <<'NOPRINCIPAL'

--principal is required, and is NOT defaulted to the account running this.

It names the person who will deploy. They are granted exactly one thing:
tokenCreator on the deploy service account, which they impersonate. They do
NOT receive the resource-admin roles — those go to the service account.

  --principal user:someone@agency.ok.gov

If the deploying person is not decided yet, run with --no-principal. The
deploy account and all its roles are still created; only the grant that lets
a human use it is deferred.

NOPRINCIPAL
  exit 64
fi

# ---------------------------------------------------------------------------
# 1. APIs.
#
# Terraform used to own these with google_project_service, which needs
# serviceusage.serviceUsageAdmin on every run — including runs that change
# nothing, because refresh reads each one. Enabling them here drops that role
# entirely.
# ---------------------------------------------------------------------------
say "Enabling ${#REQUIRED_APIS[@]} APIs"
run gcloud services enable "${REQUIRED_APIS[@]}" --project "$PROJECT"

# ---------------------------------------------------------------------------
# 2. The BigQuery Data Transfer Service agent.
#
# Enabling an API does not create its service agent — the agent appears the
# first time the service is used. So granting a role to
# service-<num>@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com right
# after enabling the API fails with "does not exist". This forces it into
# existence and prints its real address rather than string-building one.
#
# It is only needed for the freshness scheduled query, which dev disables
# (freshness_check_enabled = false) — so this is the step that would
# otherwise first fail in PROD.
# ---------------------------------------------------------------------------
say "Provisioning the BigQuery Data Transfer service agent"
run gcloud beta services identity create \
  --service=bigquerydatatransfer.googleapis.com --project "$PROJECT"

# Same reasoning, different service. Cloud Scheduler does not call Cloud Run
# as the scheduler account directly — its SERVICE AGENT impersonates that
# account to mint the OAuth token. The agent normally appears the first time
# the API is used and is granted roles/cloudscheduler.serviceAgent
# automatically, but forcing it is one call and the failure it prevents is a
# 403 on every scheduled fire, visible only in Cloud Logging because
# jobs:run returns an Operation and the scheduler records success anyway.
run gcloud beta services identity create \
  --service=cloudscheduler.googleapis.com --project "$PROJECT"

DTS_AGENT=""
if (( ! DRY_RUN )); then
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
  DTS_AGENT="service-${PROJECT_NUMBER}@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"
  SCHEDULER_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
  note "data transfer agent: $DTS_AGENT"
  note "scheduler agent    : $SCHEDULER_AGENT"
else
  DTS_AGENT="service-<project-number>@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"
  SCHEDULER_AGENT="service-<project-number>@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
fi

# ---------------------------------------------------------------------------
# 3. The Terraform state bucket.
#
# Terraform cannot create the bucket that holds its own state. Skip with
# --no-state-bucket if OMES is hosting state — "we can not hook up your
# personal Github, but we can hook up your instance with the state".
# ---------------------------------------------------------------------------
if (( SKIP_STATE_BUCKET )); then
  say "Skipping the state bucket (--no-state-bucket)"
  note "Point infra/terraform/envs/<env>/backend.tf and terraform.tfvars at"
  note "whatever bucket OMES provides, and make sure both name it identically."
else
  say "State bucket gs://$BUCKET_STATE"
  if (( ! DRY_RUN )) && gcloud storage buckets describe "gs://$BUCKET_STATE" \
       --project "$PROJECT" >/dev/null 2>&1; then
    # `describe --project X` sets the billing project for the CALL; it does
    # not assert ownership. A bucket you can merely read in ANOTHER project
    # answers here quite happily, and this environment's state would then be
    # written into that project. Prod state living in the dev project inverts
    # the trust relationship and nothing downstream would surface it.
    owner=$(gcloud storage buckets describe "gs://$BUCKET_STATE" \
      --format='value(project_number)' 2>/dev/null || true)
    mine=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
    if [[ -n "$owner" && "$owner" != "$mine" ]]; then
      echo "" >&2
      echo "gs://$BUCKET_STATE exists in a DIFFERENT project ($owner, not $mine)." >&2
      echo "Terraform state for this environment would land in that project." >&2
      exit 1
    fi
    note "already exists"
  else
    run gcloud storage buckets create "gs://$BUCKET_STATE" \
      --project "$PROJECT" --location "$LOCATION" \
      --uniform-bucket-level-access --public-access-prevention
  fi
  # Versioning is the difference between a bad apply being an inconvenience
  # and being an outage.
  run gcloud storage buckets update "gs://$BUCKET_STATE" --versioning --project "$PROJECT"
  # Soft delete defaults to 7 days on new buckets and retained deleted bytes
  # are BILLED. The flag is --clear-soft-delete, not --clear-soft-delete-policy.
  run gcloud storage buckets update "gs://$BUCKET_STATE" --clear-soft-delete --project "$PROJECT"
fi

# ---------------------------------------------------------------------------
# 3b. The source bucket — a mirror of this repository inside the project.
#
# Cloning from GitHub is the normal way in. This covers the case that has no
# clone available: access to the GCP project but not to the repo. Anyone in
# the project can then fetch the code into a fresh Cloud Shell in one line.
#
# Versioned, so a broken push is not the only copy.
# ---------------------------------------------------------------------------
say "Source bucket gs://$BUCKET_SOURCE"
if (( ! DRY_RUN )) && gcloud storage buckets describe "gs://$BUCKET_SOURCE" \
     --project "$PROJECT" >/dev/null 2>&1; then
  note "already exists"
else
  run gcloud storage buckets create "gs://$BUCKET_SOURCE" \
    --project "$PROJECT" --location "$LOCATION" \
    --uniform-bucket-level-access --public-access-prevention
fi
run gcloud storage buckets update "gs://$BUCKET_SOURCE" --versioning --project "$PROJECT"

# ---------------------------------------------------------------------------
# 4. The six runtime identities.
#
# One per pipeline, not one shared: the scraper has no business holding the
# Snowflake secret, and the Lightcast job has no business writing the scrape
# cache. Six is the whole list: there is no CI identity, because deploys run
# from Cloud Shell as a person.
# ---------------------------------------------------------------------------
say "Creating six service accounts"

create_sa() {
  local id="$1" display="$2" desc="$3"
  if (( ! DRY_RUN )) && gcloud iam service-accounts describe \
       "sa-${PREFIX}-${id}-1@${PROJECT}.iam.gserviceaccount.com" \
       --project "$PROJECT" >/dev/null 2>&1; then
    note "sa-${PREFIX}-${id}-1 already exists"
    return 0
  fi
  run gcloud iam service-accounts create "sa-${PREFIX}-${id}-1" \
    --project "$PROJECT" --display-name "$display" --description "$desc"
}

create_sa lightcast  "OWC lightcast pipeline"      "Runs the lightcast Cloud Run job. Holds the Snowflake secret."
create_sa enrollment "OWC enrollment pipeline"     "Runs the enrollment Cloud Run job. No secret access: the source is a public webpage."
create_sa scheduler  "OWC Cloud Scheduler invoker" "Invokes the Cloud Run jobs. run.developer on the specific jobs only."
create_sa build      "OWC Cloud Build"             "Runs container builds. Reads build source, writes the image and logs. Nothing else."
create_sa powerbi    "OWC PowerBI reader"          "Read-only on owc_marts. See docs/architecture.md ADR-006 for the JSON-key exception."
create_sa freshness  "OWC freshness check"         "Runs the owc_ops.pipeline_runs freshness scheduled query. Read-only."

# The seventh, and different in kind: it runs the deploy rather than being
# created by it. Terraform never sees it and nothing attaches it to a
# resource — which is why it is not in ALL_SAS and `make names-check` does
# not expect it in naming.tf.
say "Creating the deploy identity"
create_sa deploy "OWC deploy" "Runs Terraform and the gcloud deploy steps. Impersonated by a named person; no human holds its roles."

# ---------------------------------------------------------------------------
# 5. Project-level IAM for the runtime identities.
#
# These are the bindings Terraform used to make, and they are the reason it
# needed projectIamAdmin: every google_project_iam_member read-modify-writes
# the project IAM policy, so even a no-op refresh needs getIamPolicy.
#
# Everything NOT here is resource-scoped — a bucket prefix, one secret, one
# dataset, one Cloud Run job — and stays in Terraform, because setting a
# policy on a bucket you just created is inherent to creating it and needs no
# project-level permission. See docs/deploy.md for that line and
# why it is drawn there.
# ---------------------------------------------------------------------------
say "Granting ${#RUNTIME_PROJECT_GRANTS[@]} project-level roles to the runtime identities"
for grant in "${RUNTIME_PROJECT_GRANTS[@]}"; do
  key="${grant%%|*}"
  role="${grant##*|}"
  run gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:$(sa_email "$key")" \
    --role "$role" --condition=None --quiet
done

# ---------------------------------------------------------------------------
# 6. Service-account-level IAM.
#
# Two kinds, and both are invisible to a project IAM check:
#
#   tokenCreator  The Data Transfer Service mints tokens for the freshness SA
#                 when it runs the scheduled query.
#   serviceAccountUser  Attaching a service account to a Cloud Run job, a
#                 Scheduler job, a build, or a scheduled query needs actAs ON
#                 THAT ACCOUNT. A human running Terraform as project owner has
#                 actAs on everything and never sees this; a lower-privileged
#                 principal fails with
#                   Error 403: ... lacks IAM permission "iam.serviceAccounts.actAs"
# ---------------------------------------------------------------------------
say "Granting the Data Transfer agent tokenCreator on the freshness identity"
run gcloud iam service-accounts add-iam-policy-binding "$SA_FRESHNESS" \
  --project "$PROJECT" \
  --member "serviceAccount:$DTS_AGENT" \
  --role roles/iam.serviceAccountTokenCreator --quiet

# And the same for Cloud Scheduler, which impersonates the scheduler account
# to mint the OAuth token it calls Cloud Run with.
#
# roles/cloudscheduler.serviceAgent normally covers this and is granted
# automatically at the project level. An organization that strips default
# grants leaves it absent, and then every scheduled fire is a 403 that
# run.invoker cannot explain — observed on owc-dpar-d. Granting it
# explicitly costs one call and does not depend on that default surviving.
say "Granting the Cloud Scheduler agent tokenCreator on the scheduler identity"
run gcloud iam service-accounts add-iam-policy-binding "$SA_SCHEDULER" \
  --project "$PROJECT" \
  --member "serviceAccount:$SCHEDULER_AGENT" \
  --role roles/iam.serviceAccountTokenCreator --quiet

# ---------------------------------------------------------------------------
# 7. The deploy identity's roles, and the one grant a human gets.
#
# The resource-admin roles go to a SERVICE ACCOUNT, never to a person. A
# named human is granted tokenCreator on that account and impersonates it.
# Three properties follow:
#
#   auditable   every action is attributable to the person who minted the
#               token, in the same audit log entry
#   revocable   one binding removes all of it
#   compliant   no human holds an admin-level role, which is what OMES asked
#
# These grants do not depend on knowing who deploys, so they run either way.
# ---------------------------------------------------------------------------
say "Granting the deploy identity actAs on the ${#ATTACHED_SAS[@]} identities it attaches"
for target in "${ATTACHED_SAS[@]}"; do
  run gcloud iam service-accounts add-iam-policy-binding "$target" \
    --project "$PROJECT" --member "serviceAccount:$SA_DEPLOY" \
    --role roles/iam.serviceAccountUser --quiet
done

# roles/run.admin is the one an organization may refuse, and there is a
# working answer either way — so try it, fall back rather than stop, and say
# plainly what the fallback costs. Deciding this on a call should not need a
# second meeting.
say "Granting the deploy identity its ${#TF_PRINCIPAL_ROLES[@]} resource-admin roles"
RUN_ROLE="roles/run.admin"
for role in "${TF_PRINCIPAL_ROLES[@]}"; do
  if [[ "$role" == "roles/run.admin" ]] && (( NO_RUN_ADMIN )); then
    note "--no-run-admin: using roles/run.developer instead of roles/run.admin"
    role="roles/run.developer"
    RUN_ROLE="$role"
  fi
  if run gcloud projects add-iam-policy-binding "$PROJECT" \
       --member "serviceAccount:$SA_DEPLOY" --role "$role" --condition=None --quiet; then
    continue
  fi
  if [[ "$role" == "roles/run.admin" ]]; then
    note ""
    note "roles/run.admin was refused. Falling back to roles/run.developer."
    if run gcloud projects add-iam-policy-binding "$PROJECT" \
         --member "serviceAccount:$SA_DEPLOY" --role roles/run.developer \
         --condition=None --quiet; then
      RUN_ROLE="roles/run.developer"
    else
      echo "Neither roles/run.admin nor roles/run.developer could be granted." >&2
      echo "Nothing else in this script depends on it, but no deploy will work." >&2
      exit 1
    fi
  else
    echo "Could not grant $role to $SA_DEPLOY." >&2
    exit 1
  fi
done
note ""
note "NOT granted to anyone, human or service account:"
for role in "${TF_PRINCIPAL_FORBIDDEN_ROLES[@]}"; do note "  $role"; done

if (( SKIP_PRINCIPAL )); then
  note ""
  say "No operator named (--no-principal) — nobody can impersonate it yet"
  note "Re-run with --principal user:<address> once the deploying person is"
  note "decided. Everything above is already in place."
else
  say "Granting $PRINCIPAL tokenCreator on the deploy identity, and nothing else"
  run gcloud iam service-accounts add-iam-policy-binding "$SA_DEPLOY" \
    --project "$PROJECT" --member "$PRINCIPAL" \
    --role roles/iam.serviceAccountTokenCreator --quiet
  note ""
  note "$PRINCIPAL now holds exactly one binding in this project:"
  note "  tokenCreator on $SA_DEPLOY"
  note "They deploy by impersonating it. See docs/deploy.md#deploy-identity."
fi

# The one thing that changes what the operator has to do next, so it is
# printed before the generic steps rather than buried in them.
if [[ "$RUN_ROLE" == "roles/run.developer" ]]; then
  say "IMPORTANT — the deploy identity has run.developer, not run.admin"
  cat <<RUNDEV

  That is a supported configuration, but it is not finished. run.developer
  cannot write a Cloud Run job's IAM policy, so Terraform cannot grant Cloud
  Scheduler permission to start the jobs. Two things follow.

  1. THE OPERATOR sets this in infra/terraform/envs/<env>/terraform.tfvars
     before deploying, or the apply fails on that one resource:

       scheduler_job_iam_in_terraform = false

  2. YOU run two more commands AFTER their first successful deploy — the
     Cloud Run jobs have to exist before anything can be granted on them:

       make scheduler-grant ENV=<env>

     prints both with the names filled in, or they are:

       gcloud run jobs add-iam-policy-binding $JOB_LIGHTCAST \\
         --region <region> --project $PROJECT \\
         --member serviceAccount:$SA_SCHEDULER \\
         --role roles/run.developer

       ...and the same for $JOB_ENROLLMENT.

  Until step 2 is done every scheduled run returns 403. It is silent: the
  jobs work when started by hand and fail on the monthly cron. Both
  'make verify-separation' and 'make scheduler-debug' report the gap.

  To avoid all of this, grant the deploy account roles/run.admin instead —
  it is the same account, which no human logs in as.

RUNDEV
fi

# ---------------------------------------------------------------------------
if (( DRY_RUN )); then
  say "Dry run complete — NOTHING above was executed"
  cat <<DRYNEXT

  No project was changed. Nothing exists yet.

  To actually create it, re-run without --dry-run:

    make gcloud-admin ENV=<env>

  Or send the commands above to whoever holds serviceAccountAdmin and
  projectIamAdmin on $PROJECT, and have them run them.

  Only then do the rest: make iam-check, make source-push, make up.
  docs/deploy.md has the order.
DRYNEXT
  exit 0
fi

say "Done"
cat <<NEXT

  Next, in order. ENV is dev or prod — whichever project this was.

    1. Verify what this created, including that the forbidden roles are absent:

         make iam-check ENV=<env>

    2. Mirror this repository into the project, for anyone who has GCP
       access but cannot clone from GitHub:

         make source-push ENV=<env>

    3. Stand the environment up. It stops once to ask for the Snowflake
       password — the secret container does not exist until this creates it:

         make up ENV=<env>

    4. Store the password, then re-run 'make up ENV=<env>':

         printf '%s' 'THE_PASSWORD' | \\
           gcloud secrets versions add $SECRET_SNOWFLAKE --data-file=- --project $PROJECT

    5. Prove it end to end:

         make smoke ENV=<env>

  The full walkthrough, with what each step does and why, is the only other
  place this procedure is written down:

    docs/deploy.md
NEXT
