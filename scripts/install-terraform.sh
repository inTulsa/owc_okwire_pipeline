#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install terraform into $HOME, where it survives a Cloud Shell session.
#
# Cloud Shell does not ship terraform, and the apt route it suggests does not
# persist: only $HOME survives, so an apt-installed binary under /usr is gone
# next session and every deploy starts with a reinstall. Putting it in
# ~/bin fixes that.
#
# The checksum is verified. This binary is about to run against production
# infrastructure with credentials attached; "curl | unzip" is not good enough.
#
#   ./scripts/install-terraform.sh            # the rehearsed version
#   TF_VERSION=1.14.0 ./scripts/install-terraform.sh
# ---------------------------------------------------------------------------
set -euo pipefail

# The version this repo has been rehearsed on. versions.tf requires >= 1.9.
TF_VERSION="${TF_VERSION:-1.13.4}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"

case "$(uname -s)" in
  Linux)  os=linux ;;
  Darwin) os=darwin ;;
  *) echo "unsupported OS: $(uname -s). Install terraform by hand." >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)." >&2; exit 1 ;;
esac

zip="terraform_${TF_VERSION}_${os}_${arch}.zip"
base="https://releases.hashicorp.com/terraform/${TF_VERSION}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo ">> downloading terraform ${TF_VERSION} (${os}/${arch})"
curl -fsSL -o "$tmp/$zip"        "$base/$zip"
curl -fsSL -o "$tmp/SHA256SUMS"  "$base/terraform_${TF_VERSION}_SHA256SUMS"

echo ">> verifying checksum"
want=$(awk -v f="$zip" '$2 == f {print $1}' "$tmp/SHA256SUMS")
if [[ -z "$want" ]]; then
  echo "no checksum published for $zip — refusing to install." >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp/$zip" | awk '{print $1}')
else
  got=$(shasum -a 256 "$tmp/$zip" | awk '{print $1}')
fi
if [[ "$want" != "$got" ]]; then
  echo "CHECKSUM MISMATCH for $zip — refusing to install." >&2
  echo "  expected $want" >&2
  echo "  got      $got" >&2
  exit 1
fi
echo "   ok: $got"

mkdir -p "$BIN_DIR"
unzip -o -q "$tmp/$zip" terraform -d "$BIN_DIR"
chmod +x "$BIN_DIR/terraform"
echo ">> installed $BIN_DIR/terraform"

# Being on PATH is the whole point; a binary in a directory nothing searches
# is the same as not installing it, and "now go edit your shell config" is a
# step that has cost a round trip every time it has been printed.
#
# Debian's ~/.profile does add $HOME/bin — but only if it exists AT LOGIN.
# We just created it, so this session will not have picked it up, and in
# Cloud Shell a session is cheap to be in the middle of. So make it work
# now and make it stick, rather than describing how.
#
# Set SKIP_PATH_SETUP=1 to manage your own shell config.
LINE="export PATH=\"$BIN_DIR:\$PATH\""
RC="${RC_FILE:-$HOME/.bashrc}"

if [ -n "${SKIP_PATH_SETUP:-}" ]; then
  echo ""
  echo "  SKIP_PATH_SETUP is set. Add this yourself:"
  echo "    $LINE"
  echo ""
elif case ":$PATH:" in *":$BIN_DIR:"*) true ;; *) false ;; esac; then
  echo ">> $BIN_DIR is already on PATH"
  "$BIN_DIR/terraform" version | head -1
else
  if [ -f "$RC" ] && grep -qF "$BIN_DIR" "$RC"; then
    echo ">> $RC already references $BIN_DIR"
  else
    printf '\n# added by owc install-terraform\n%s\n' "$LINE" >> "$RC"
    echo ">> added $BIN_DIR to PATH in $RC (for future sessions)"
  fi
  echo ""
  echo "  This shell started before that, so it needs the export once."
  echo "  Copy this line, or just open a new Cloud Shell tab:"
  echo ""
  echo "    $LINE"
  echo ""
  "$BIN_DIR/terraform" version | head -1
fi
