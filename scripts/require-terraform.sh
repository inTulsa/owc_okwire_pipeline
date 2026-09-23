#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Fail early and clearly when terraform is not usable.
#
# This exists because of a specific, silent failure. Cloud Shell does NOT ship
# terraform; what it ships is a stub that prints HashiCorp's apt install
# instructions. Depending on how it is invoked that stub can exit ZERO, and
# then:
#
#   cd envs/prod && terraform init && terraform apply -target=...
#
# "succeeds" without doing anything. make goes on to print
#
#   >> Artifact Registry and the secret container exist
#
# which is false, and the first thing anyone notices is
#
#   ERROR: (gcloud.secrets.versions.add) NOT_FOUND: Secret [...] not found
#
# several steps later, pointing at Secret Manager rather than at terraform.
#
# "The binary is on PATH" is therefore not the test. The test is "it reports
# a version", because the stub cannot.
# ---------------------------------------------------------------------------
set -uo pipefail

MIN=1.9.0

# Tolerant of anything printed before the JSON, and falls back to the plain
# output. Returns non-zero when no version can be established at all.
tf_version() {
  terraform version -json 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
i = raw.find("{")
if i < 0:
    raise SystemExit(1)
print(json.loads(raw[i:])["terraform_version"])
' 2>/dev/null && return 0
  terraform version 2>/dev/null \
    | sed -n 's/^Terraform v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | head -1 | grep .
}

# A real terraform sitting in ~/bin that this shell cannot see is a
# different problem from no terraform, and telling someone to install it
# again does not fix it. Check before reporting.
installed_elsewhere() {
  [ -x "$HOME/bin/terraform" ] && ! command -v terraform >/dev/null 2>&1 && return 0
  [ -x "$HOME/bin/terraform" ] && [ "$(command -v terraform)" != "$HOME/bin/terraform" ] \
    && "$HOME/bin/terraform" version >/dev/null 2>&1 && return 0
  return 1
}

ver_ge() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}

if v=$(tf_version) && [ -n "$v" ]; then
  if ver_ge "$v" "$MIN"; then
    exit 0
  fi
  {
    echo ""
    echo "terraform $v is too old — this repo needs >= $MIN (see versions.tf)."
    echo ""
    echo "  make install-terraform"
    echo ""
  } >&2
  exit 1
fi

if installed_elsewhere; then
  {
    echo ""
    echo "terraform is installed at \$HOME/bin/terraform, but this shell's PATH"
    echo "does not include it — so terraform commands here run the Cloud Shell"
    echo "stub instead, or nothing at all."
    echo ""
    echo "Fix this shell:"
    echo ""
    echo "    export PATH=\"\$HOME/bin:\$PATH\""
    echo ""
    echo "New Cloud Shell tabs already have it — install-terraform added it to"
    echo "~/.bashrc. Nothing was changed. Re-run this command afterwards."
    echo ""
  } >&2
  exit 1
fi

{
  echo ""
  if command -v terraform >/dev/null 2>&1; then
    echo "terraform is on PATH at $(command -v terraform) but will not report a"
    echo "version, so it is not a working terraform."
    echo ""
    echo "In Cloud Shell that is the stub which prints apt install instructions."
    echo "It can exit 0, which makes 'terraform apply' look like it succeeded"
    echo "while creating nothing."
  else
    echo "terraform is not installed."
  fi
  echo ""
  echo "Install it into \$HOME so it survives the session:"
  echo ""
  echo "    make install-terraform"
  echo ""
  echo "Nothing was changed. Re-run this command afterwards."
  echo ""
} >&2
exit 1
