#!/usr/bin/env bash
# Set up this Linux box as a self-hosted GitHub Actions runner for chaim354/tinkerex.
# Usage:  ./ci/runners/setup-linux.sh <REGISTRATION_TOKEN>
# Mint the token with:
#   gh api -X POST repos/chaim354/tinkerex/actions/runners/registration-token --jq .token
set -euo pipefail

TOKEN="${1:?Usage: setup-linux.sh <REGISTRATION_TOKEN>}"
REPO_URL="https://github.com/chaim354/tinkerex"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-tinkerex}"
LABELS="self-hosted,linux,maker-linux"

echo "==> Installing prereqs (sudo may prompt)"
sudo apt-get update
sudo apt-get install -y \
  curl jq tar git \
  libfuse-dev fuse pkg-config build-essential \
  rclone autoconf automake libtool
# AutoUnmount on the maker-mount needs user_allow_other (mount-conformance job).
grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  echo 'user_allow_other' | sudo tee -a /etc/fuse.conf >/dev/null

echo "==> Configuring the CI environment (passwordless sudo + tool cache)"
# Workflow steps run `sudo apt-get`/`sudo tee` non-interactively (GitHub-hosted images have
# passwordless sudo; a self-hosted box doesn't by default → the steps fail). Grant it for the
# runner user. (Acceptable on a private CI box; remove the drop-in to revoke.)
RUNNER_USER="$(id -un)"
echo "$RUNNER_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/github-runner-$RUNNER_USER" >/dev/null
sudo chmod 0440 "/etc/sudoers.d/github-runner-$RUNNER_USER"
# `ruby/setup-ruby` (and other setup-* actions) install into RUNNER_TOOL_CACHE, which resolves
# to /opt/hostedtoolcache here; it must exist and be writable by the runner user.
sudo mkdir -p /opt/hostedtoolcache && sudo chown "$RUNNER_USER" /opt/hostedtoolcache

echo "==> Installing Rust (rustup) if missing"
if ! command -v cargo >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

echo "==> Downloading the latest GitHub Actions runner"
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"
VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"
TARBALL="actions-runner-linux-x64-${VERSION}.tar.gz"
if [ ! -f "$TARBALL" ]; then
  curl -fsSL -o "$TARBALL" \
    "https://github.com/actions/runner/releases/download/v${VERSION}/${TARBALL}"
fi
tar xzf "$TARBALL"

echo "==> Configuring the runner (labels: $LABELS)"
# --replace makes re-running idempotent (reuses the name instead of erroring).
./config.sh --unattended --replace \
  --url "$REPO_URL" --token "$TOKEN" \
  --name "$(hostname)-maker-linux" --labels "$LABELS"

echo "==> Installing + starting the runner service"
sudo ./svc.sh install
sudo ./svc.sh start

echo "==> Done. Verify with:"
echo "    gh api repos/chaim354/tinkerex/actions/runners --jq '.runners[].name'"
