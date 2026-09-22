#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Check a workstation has what this repo needs, before it needs it.
#
# A tooling problem is the worst kind to hit in the middle of a GCP setup,
# because it does not look like one. A missing bq component surfaces as a
# failed query; the wrong Application Default Credentials surface as
# "bucket doesn't exist". Both cost an afternoon. This costs a second.
#
# Exits non-zero if anything REQUIRED is missing. Optional items warn.
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

echo ""
echo "Toolchain"
echo ""

if v=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null); then
  if ver_ge "$v" 1.9.0; then ok terraform "$v  (CI pins 1.13.4)"; else bad terraform "$v — need >= 1.9, see versions.tf"; fi
else
  bad terraform "not installed — https://developer.hashicorp.com/terraform/install"
fi

if v=$(python3 -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null); then
  if ver_ge "$v" 3.12.0; then ok python3 "$v"; else bad python3 "$v — need >= 3.12"; fi
else
  bad python3 "not installed"
fi

command -v uv    >/dev/null && ok uv    "$(uv --version 2>&1 | awk '{print $2}')" \
                            || bad uv   "not installed — curl -LsSf https://astral.sh/uv/install.sh | sh"
command -v git   >/dev/null && ok git   "$(git --version | awk '{print $3}')"   || bad git "not installed"
command -v make  >/dev/null && ok make  "$(make --version | head -1 | awk '{print $3}')" || bad make "not installed"

if command -v gcloud >/dev/null; then
  ok gcloud "$(gcloud version 2>/dev/null | awk '/Google Cloud SDK/{print $4}')"
  # bq ships with the SDK but can be absent from minimal installs, and its
  # absence shows up much later as a failed query rather than a missing tool.
  command -v bq >/dev/null && ok bq "installed" \
                           || bad bq "missing — gcloud components install bq"
else
  bad gcloud "not installed — https://cloud.google.com/sdk/docs/install"
  bad bq     "ships with the gcloud SDK"
fi

command -v gh >/dev/null && ok gh "$(gh version | head -1 | awk '{print $3}')" \
                         || warn gh "not installed — only needed for 'make gh-vars'"

echo ""
echo "Not required: Docker. Images build in Cloud Build; nothing here runs a local daemon."
echo ""
echo "Credentials"
echo ""

# gcloud's own login and Terraform's Application Default Credentials are
# SEPARATE. Having one without the other is the most common way a fresh
# machine fails, and the error it produces names neither.
acct=$(gcloud config get-value account 2>/dev/null | grep -v '^$' || true)
[ -n "$acct" ] && ok "gcloud auth" "$acct" \
               || bad "gcloud auth" "run: gcloud auth login"

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  adc_file="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
  quota=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('quota_project_id',''))" "$adc_file" 2>/dev/null || true)
  if [ -n "$quota" ]; then
    ok "ADC" "quota project: $quota"
  else
    warn "ADC" "no quota project set — gcloud auth application-default set-quota-project <PROJECT>"
  fi
else
  bad "ADC" "Terraform has no credentials — run: gcloud auth application-default login"
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo "Something required is missing. See docs/08-developer-setup.md."
  exit 1
fi
echo "Ready. Next: docs/03-gcp-setup.md"
