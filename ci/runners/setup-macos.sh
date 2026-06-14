#!/usr/bin/env bash
# Set up this macOS box as a self-hosted GitHub Actions runner for chaim354/tinkerex.
# This box runs the macOS cross-check job: `cargo check --target x86_64-pc-windows-gnu`
# (the CfAPI Windows-FFI typecheck) plus native fs-webdav / sync-engine builds.
# Usage:  ./ci/runners/setup-macos.sh <REGISTRATION_TOKEN>
#   gh api -X POST repos/chaim354/tinkerex/actions/runners/registration-token --jq .token
set -euo pipefail

TOKEN="${1:?Usage: setup-macos.sh <REGISTRATION_TOKEN>}"
REPO_URL="https://github.com/chaim354/tinkerex"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-tinkerex}"
LABELS="self-hosted,macos,maker-mac"

command -v brew >/dev/null 2>&1 || { echo "Homebrew required: https://brew.sh"; exit 1; }

echo "==> Installing prereqs via Homebrew"
brew install jq mingw-w64 rclone || true   # mingw-w64 = linker for the windows-gnu cross-check

echo "==> Installing Rust (rustup) if missing + the Windows cross-target"
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
rustup target add x86_64-pc-windows-gnu

# arch: Apple Silicon → arm64, Intel → x64
ARCH="$( [ "$(uname -m)" = "arm64" ] && echo arm64 || echo x64 )"

echo "==> Downloading the latest GitHub Actions runner (osx-$ARCH)"
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"
VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"
TARBALL="actions-runner-osx-${ARCH}-${VERSION}.tar.gz"
if [ ! -f "$TARBALL" ]; then
  curl -fsSL -o "$TARBALL" \
    "https://github.com/actions/runner/releases/download/v${VERSION}/${TARBALL}"
fi
tar xzf "$TARBALL"

echo "==> Configuring the runner (labels: $LABELS)"
./config.sh --unattended --replace \
  --url "$REPO_URL" --token "$TOKEN" \
  --name "$(hostname -s)-maker-mac" --labels "$LABELS"

echo "==> Installing + starting the runner service (launchd)"
./svc.sh install
./svc.sh start

echo "==> Done. NOTE: fs-fuse on macOS needs the FUSE-T pkg-config alias (client/fs-fuse/BUILD.md)"
echo "    only if a job builds fs-fuse here; the cross-check + fs-webdav build do not."
echo "    Verify: gh api repos/chaim354/tinkerex/actions/runners --jq '.runners[].name'"
