#!/usr/bin/env bash
set -euo pipefail

if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw CLI not found in PATH."
  echo "Install OpenClaw first, then re-run this script."
  exit 1
fi

REPO_URL="${REPO_URL:-https://github.com/answerlink/openclaw-plugin-worktool}"
REF="${REF:-main}"
TMP_DIR="$(mktemp -d)"
ARCHIVE_PATH="$TMP_DIR/worktool-plugin.tar.gz"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Downloading plugin from ${REPO_URL} (${REF})..."
curl -fsSL "${REPO_URL}/archive/refs/heads/${REF}.tar.gz" -o "$ARCHIVE_PATH"

echo "Extracting..."
tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"
PLUGIN_DIR="$(find "$TMP_DIR" -maxdepth 1 -type d -name 'openclaw-plugin-worktool-*' | head -n 1)"

if [ -z "${PLUGIN_DIR}" ]; then
  echo "Failed to locate extracted plugin directory."
  exit 1
fi

echo "Installing with OpenClaw..."
openclaw plugins install "$PLUGIN_DIR"

echo "Done. Next: update openclaw.json with robotId / bridgeBaseUrl / gateway token."
