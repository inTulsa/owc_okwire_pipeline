#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Why is Cloud Scheduler getting 403 from a Cloud Run job?
#
# Collects, in one pass, every fact that distinguishes the causes — because
# guessing at this from a truncated log entry has already cost two rounds.
# Read-only.
#
#   ./infra/gcloud/05-scheduler-debug.sh owc-dpar-d owc-dpar-d us-central1
# ---------------------------------------------------------------------------
set -uo pipefail

PROJECT="${1:-}"; PREFIX="${2:-$PROJECT}"; REGION="${3:-us-central1}"
[[ -n "$PROJECT" ]] || { echo "usage: $0 <project> [prefix] [region]" >&2; exit 64; }

# shellcheck source=names.sh
source "$(dirname "${BASH_SOURCE[0]}")/names.sh"

head2() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mNO\033[0m    %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }

BINDING_MATCHER='
import json, sys
role, member = sys.argv[1], sys.argv[2]
policy = json.load(sys.stdin)
sys.exit(0 if any(b.get("role")==role and member in b.get("members",[])
                  for b in policy.get("bindings", [])) else 1)
'

printf '\n\033[1mScheduler 403 diagnosis — %s\033[0m\n' "$PROJECT"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null)
SCHED_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"

# --- 1. the grant the job itself carries -----------------------------------
head2 "1. run.invoker on each job, exact binding"
for job in "$JOB_LIGHTCAST" "$JOB_ENROLLMENT"; do
  if pol=$(gcloud run jobs get-iam-policy "$job" --region "$REGION" \
        --project "$PROJECT" --format=json 2>&1); then
    if python3 -c "$BINDING_MATCHER" roles/run.invoker \
         "serviceAccount:$SA_SCHEDULER" <<<"$pol"; then
      ok "$job: scheduler is in the run.invoker binding"
    else
      bad "$job: scheduler is NOT in the run.invoker binding"
      note "gcloud run jobs add-iam-policy-binding $job --region $REGION \\"
      note "  --project $PROJECT --member serviceAccount:$SA_SCHEDULER \\"
      note "  --role roles/run.invoker"
    fi
  else
    bad "$job: cannot read its IAM policy"
    note "$(tail -1 <<<"$pol")"
  fi
done

# --- 2. what the scheduler is actually configured to send ------------------
head2 "2. What each scheduler sends"
if jobs=$(gcloud scheduler jobs list --location "$REGION" --project "$PROJECT" \
      --format='value(name)' 2>/dev/null); then
  while read -r j; do
    [[ -n "$j" ]] || continue
    short="${j##*/}"
    sa=$(gcloud scheduler jobs describe "$short" --location "$REGION" \
      --project "$PROJECT" --format='value(httpTarget.oauthToken.serviceAccountEmail)' 2>/dev/null)
    uri=$(gcloud scheduler jobs describe "$short" --location "$REGION" \
      --project "$PROJECT" --format='value(httpTarget.uri)' 2>/dev/null)
    if [[ "$sa" == "$SA_SCHEDULER" ]]; then
      ok "$short -> oauth as ${sa%%@*}"
    else
      bad "$short -> oauth as '${sa:-<none>}', expected ${SA_SCHEDULER%%@*}"
    fi
    note "$uri"
  done <<< "$jobs"
else
  bad "cannot list scheduler jobs"
fi

# --- 3. the agent that mints the token -------------------------------------
#
# This is the one nothing in this repo provisions. Cloud Scheduler does not
# use the scheduler service account directly: its SERVICE AGENT impersonates
# it to mint the OAuth token. If that agent is absent, or lost its automatic
# roles/cloudscheduler.serviceAgent grant, every fire is a 403 no matter how
# correct the run.invoker binding is.
head2 "3. Cloud Scheduler service agent"
if gcloud iam service-accounts describe "$SCHED_AGENT" --project "$PROJECT" >/dev/null 2>&1; then
  ok "exists: $SCHED_AGENT"
else
  # Absent is not proof of fault — agents are often not listable — but it is
  # the first thing worth forcing.
  bad "not visible: $SCHED_AGENT"
  note "Force it into existence (needs serviceusage rights):"
  note "  gcloud beta services identity create \\"
  note "    --service=cloudscheduler.googleapis.com --project $PROJECT"
fi

head2 "4. Can that agent impersonate the scheduler account?"
if pol=$(gcloud iam service-accounts get-iam-policy "$SA_SCHEDULER" \
      --project "$PROJECT" --format=json 2>&1); then
  if python3 -c "$BINDING_MATCHER" roles/iam.serviceAccountTokenCreator \
       "serviceAccount:$SCHED_AGENT" <<<"$pol"; then
    ok "agent has tokenCreator on ${SA_SCHEDULER%%@*}"
  else
    bad "agent has NO tokenCreator on ${SA_SCHEDULER%%@*}"
    note "Usually implicit via roles/cloudscheduler.serviceAgent at the"
    note "project level. If an org policy strips default grants, it is not,"
    note "and this is the 403. Ask your project admin for:"
    note "  gcloud iam service-accounts add-iam-policy-binding $SA_SCHEDULER \\"
    note "    --project $PROJECT --member serviceAccount:$SCHED_AGENT \\"
    note "    --role roles/iam.serviceAccountTokenCreator"
  fi
else
  bad "cannot read the scheduler account's policy"
  note "$(tail -1 <<<"$pol")"
fi

# --- 5. the untruncated failure --------------------------------------------
head2 "5. Most recent scheduler attempt, in full"
# The formatter lives in a variable, not inline after `python3 -c '`.
# Inline, the single quotes around a dict key close the shell string: the
# first attempt printed
#   SyntaxError: unexpected character after line continuation character
# because bash had already eaten the quotes before python saw them.
LAST_ATTEMPT=$(cat <<'PY'
import json, sys
try:
    entries = json.load(sys.stdin)
except Exception:
    print("        (could not read logs)")
    raise SystemExit
if not entries:
    print("        (no scheduler attempts logged yet)")
    raise SystemExit
entry = entries[0]
payload = entry.get("jsonPayload", {})
for key in ("jobName", "targetType", "status", "debugInfo", "url"):
    if key in payload:
        print("        %-11s %s" % (key, payload[key]))
print("        %-11s %s" % ("timestamp", entry.get("timestamp", "")))
PY
)
gcloud logging read \
  "resource.type=cloud_scheduler_job AND resource.labels.project_id=$PROJECT" \
  --project "$PROJECT" --limit 1 --format=json 2>/dev/null \
  | python3 -c "$LAST_ATTEMPT"
echo ""
