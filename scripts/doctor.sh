#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Check this environment has what the repo needs, before it needs it.
#
# A tooling problem hit in the middle of a GCP setup does not look like a
# tooling problem. A missing bq component surfaces as a failed query; the
# wrong Application Default Credentials surface as "bucket doesn't exist".
# Both cost an afternoon. This costs a second.
#
# Two groups, because they are genuinely different jobs:
#
#   DEPLOY       stand an environment up and operate it. gcloud, terraform,
#                bash, make, git, any python3. No virtualenv, no uv, no
#                Python 3.12. Everything in `make up` is shell and API calls.
#   DEVELOPMENT  run the pipelines, the tests, the linters. Needs the venv,
#                which needs uv and Python 3.12.
#
# Cloud Shell has everything in the first group preinstalled, which is why
# the first group is the required one: it is the difference between "open
# Cloud Shell and go" and "install a toolchain first".
#
# Exits non-zero only if something in DEPLOY is missing.
# ---------------------------------------------------------------------------
set -uo pipefail

fail=0
ok()   { printf '  \033[32mok\033[0m       %-12s %s\n' "$1" "$2"; }
bad()  { printf '  \033[31mMISSING\033[0m  %-12s %s\n' "$1" "$2"; fail=1; }
warn() { printf '  \033[33mwarn\033[0m     %-12s %s\n' "$1" "$2"; }

# True when $1 >= $2. Uses sort's numeric key fields rather than sort -V,
# which BSD/macOS sort does not have. Missing fields sort as 0, so "3.13"
# and "3.13.0" compare equal.
ver_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}

# Cloud Shell sets both; CLOUD_SHELL is the documented one. The distinction
# changes the advice this script gives more than it changes the checks:
# gcloud is already authenticated there, Docker and a toolchain install are
# not something to go and do, and $HOME is the only durable directory.
IN_CLOUD_SHELL=0
if [ "${CLOUD_SHELL:-}" = "true" ] || [ -n "${GOOGLE_CLOUD_SHELL:-}" ]; then
  IN_CLOUD_SHELL=1
fi

echo ""
if (( IN_CLOUD_SHELL )); then
  printf '\033[1mGoogle Cloud Shell\033[0m  (project: %s)\n' "${DEVSHELL_PROJECT_ID:-unset}"
else
  printf '\033[1mLocal machine\033[0m\n'
fi

echo ""
echo "Deploy — required. This is all 'make up' needs."
echo ""

if command -v gcloud >/dev/null; then
  ok gcloud "$(gcloud version 2>/dev/null | awk '/Google Cloud SDK/{print $4}')"
  # bq ships with the SDK but is absent from minimal installs, and its
  # absence shows up much later as a failed query rather than a missing tool.
  command -v bq >/dev/null && ok bq "installed" \
                           || bad bq "missing — gcloud components install bq"
else
  bad gcloud "not installed — https://cloud.google.com/sdk/docs/install"
  bad bq     "ships with the gcloud SDK"
fi

if v=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null); then
  if ver_ge "$v" 1.9.0; then ok terraform "$v  (rehearsed on 1.13.4)"; else bad terraform "$v — need >= 1.9, see versions.tf"; fi
elif command -v terraform >/dev/null; then
  ok terraform "installed (version not parseable)"
elif (( IN_CLOUD_SHELL )); then
  bad terraform "not on PATH — unexpected in Cloud Shell; try: sudo apt-get install -y terraform"
else
  bad terraform "not installed — https://developer.hashicorp.com/terraform/install"
fi

# Any python3. The deploy scripts use it only to parse small JSON blobs with
# the standard library; 3.12 is a DEVELOPMENT requirement, checked below.
if v=$(python3 -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null); then
  ok python3 "$v"
else
  bad python3 "not installed"
fi

command -v git  >/dev/null && ok git  "$(git --version | awk '{print $3}')"            || bad git  "not installed"
command -v make >/dev/null && ok make "$(make --version | head -1 | awk '{print $3}')" || bad make "not installed"
command -v bash >/dev/null && ok bash "$(bash --version | head -1 | awk '{print $4}')" || bad bash "not installed"

echo ""
echo "Development — optional. Needed for 'make check', 'make test', 'make run'."
echo ""

if v=$(python3 -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null); then
  if ver_ge "$v" 3.12.0; then
    ok "python 3.12" "$v"
  else
    # Not a blocker: `make setup` runs `uv venv --python 3.12`, and uv
    # downloads that interpreter rather than using the system one. Worth
    # saying, because "system python is 3.11" reads like a wall and is not.
    warn "python 3.12" "system python3 is $v — 'make setup' has uv fetch 3.12, so this is fine"
  fi
fi

command -v uv >/dev/null && ok uv "$(uv --version 2>&1 | awk '{print $2}')" \
  || warn uv "not installed — needed only by 'make setup'/'make lock': curl -LsSf https://astral.sh/uv/install.sh | sh"

if [ -x .venv/bin/python ]; then
  ok venv "$(.venv/bin/python -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)"
else
  warn venv "not created — run 'make setup' if you want to run tests or pipelines locally"
fi

command -v gh >/dev/null && ok gh "$(gh version | head -1 | awk '{print $3}')" \
  || warn gh "not installed — only 'make gh-vars', which needs enable_wif = true"

echo ""
echo "Not required: Docker. Images build in Cloud Build; nothing here runs a local daemon."
echo ""
echo "Credentials"
echo ""

# gcloud's own login and Terraform's Application Default Credentials are
# SEPARATE, and having one without the other is the most common way this
# fails. In Cloud Shell the first is free and the second is not, which is
# exactly the half people skip.
acct=$(gcloud config get-value account 2>/dev/null | grep -v '^$' || true)
if [ -n "$acct" ]; then
  ok "gcloud auth" "$acct"
elif (( IN_CLOUD_SHELL )); then
  bad "gcloud auth" "no active account — unexpected in Cloud Shell; run: gcloud auth login"
else
  bad "gcloud auth" "run: gcloud auth login"
fi

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  adc_file="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
  quota=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('quota_project_id',''))" "$adc_file" 2>/dev/null || true)
  if [ -n "$quota" ]; then
    ok "ADC" "quota project: $quota"
  else
    warn "ADC" "no quota project set — gcloud auth application-default set-quota-project <PROJECT>"
  fi
else
  if (( IN_CLOUD_SHELL )); then
    bad "ADC" "Terraform has no credentials. Cloud Shell logs gcloud in for you but NOT Terraform: gcloud auth application-default login"
  else
    bad "ADC" "Terraform has no credentials — run: gcloud auth application-default login"
  fi
fi

if (( IN_CLOUD_SHELL )); then
  echo ""
  echo "Cloud Shell notes"
  echo ""
  # Compare resolved paths, not the raw strings: a symlinked or
  # trailing-slashed $HOME would otherwise produce a "your work will be
  # wiped" warning that is both alarming and wrong.
  here=$(cd -P . 2>/dev/null && pwd)
  home=$(cd -P "$HOME" 2>/dev/null && pwd)
  case "$here" in
    "$home"|"$home"/*)
      ok "workspace" "$here is under \$HOME, which persists between sessions" ;;
    *)
      warn "workspace" "$here is OUTSIDE \$HOME and is wiped when this session ends — move the repo under ~/" ;;
  esac
  printf '  \033[2m%s\033[0m\n' "\$HOME persists, but is deleted after 120 days of inactivity."
  printf '  \033[2m%s\033[0m\n' "Losing it costs one git clone, or a fetch from gs://gcs-<prefix>-source-1."
  printf '  \033[2m%s\033[0m\n' "Sessions end after ~20 min idle. A long apply is safer under tmux,"
  printf '  \033[2m%s\033[0m\n' "which Cloud Shell already runs: reattach with 'tmux attach'."
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo "Something required is missing. See docs/08-developer-setup.md."
  exit 1
fi
echo "Ready. Next: docs/09-gcloud-deploy.md"
