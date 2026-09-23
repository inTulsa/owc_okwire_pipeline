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
# is the same as not installing it.
case ":$PATH:" in
  *":$BIN_DIR:"*)
    echo ">> $BIN_DIR is already on PATH"
    "$BIN_DIR/terraform" version | head -1
    ;;
  *)
    echo ""
    echo "  $BIN_DIR is NOT on your PATH. Add it for this session:"
    echo ""
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
    echo "  and for future ones:"
    echo ""
    echo "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
    echo ""
    ;;
esac
