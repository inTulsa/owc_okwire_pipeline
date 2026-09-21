#!/usr/bin/env bash
# Print a Terraform output for one environment, or fail with a message that
# says what to do.
#
# Uses `terraform output -json` rather than `-raw`, because on an environment
# with no state `terraform output` prints a "No outputs found" WARNING BOX TO
# STDOUT and exits 0. A naive check therefore sees non-empty output, succeeds,
# and hands that warning text to whatever consumes it — which is how
# `gh variable set --body "$(...)"` nearly got a variable full of ANSI escape
# codes. `-json` emits exactly `{}` in that case, with nothing to mistake.
#
#   scripts/tf-output.sh <env-dir> <env-name> <project> [output-name]
set -uo pipefail

DIR="${1:?env dir}"; ENV_NAME="${2:?env name}"; PROJECT="${3:-<project>}"; NAME="${4:-}"

fail() {
  {
    echo ""
    echo "$1"
    echo ""
    echo "That environment has no state — nothing has been applied to it yet."
    echo "Bootstrap it first:"
    echo "  ./infra/bootstrap/bootstrap.sh $PROJECT"
    echo "  make tf-bootstrap ENV=$ENV_NAME"
    echo "  make build ENV=$ENV_NAME"
    echo "  make tf-apply ENV=$ENV_NAME TF_ARGS=\"-var=image_digest=\$(make -s image-digest ENV=$ENV_NAME)\""
    echo ""
    echo "Full walkthrough: docs/03-gcp-setup.md"
    echo ""
  } >&2
  exit 1
}

cd "$DIR" 2>/dev/null || { echo "no such environment directory: $DIR" >&2; exit 1; }

# The backend may not be initialized in a fresh clone or a never-applied env.
terraform output -json >/dev/null 2>&1 || terraform init -reconfigure >/dev/null 2>&1 || true

json=$(terraform output -json 2>/dev/null)
[ -n "$json" ] && [ "$json" != "{}" ] || fail "No Terraform outputs for ENV=$ENV_NAME."

if [ -z "$NAME" ]; then
  terraform output
  exit 0
fi

value=$(printf '%s' "$json" | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
if name not in data:
    sys.exit(1)
v = data[name]["value"]
print(v if isinstance(v, str) else json.dumps(v))
' "$NAME") || fail "Terraform output [$NAME] does not exist for ENV=$ENV_NAME."

[ -n "$value" ] || fail "Terraform output [$NAME] is empty for ENV=$ENV_NAME."
printf '%s\n' "$value"
