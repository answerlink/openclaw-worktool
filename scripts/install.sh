#!/usr/bin/env bash
set -euo pipefail

if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw CLI not found in PATH."
  echo "Install OpenClaw first, then re-run this script."
  exit 1
fi

REPO="${REPO:-answerlink/openclaw-worktool}"
VERSION="${VERSION:-latest}" # e.g. 0.2.1 or latest
ROBOT_ID="${ROBOT_ID:-}"
BRIDGE_BASE_URL="${BRIDGE_BASE_URL:-https://api.worktool.ymdyes.cn}"
WEBHOOK_HOST="${WEBHOOK_HOST:-0.0.0.0}"
WEBHOOK_PORT="${WEBHOOK_PORT:-18799}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/wechat/webhook}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
TMP_DIR="$(mktemp -d)"
ARCHIVE_PATH="$TMP_DIR/worktool-plugin.tgz"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

resolve_version() {
  if [ "$VERSION" != "latest" ]; then
    echo "$VERSION"
    return 0
  fi
  local tag
  tag="$(
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1
  )"
  if [ -z "$tag" ]; then
    echo "Failed to resolve latest release version from GitHub." >&2
    exit 1
  fi
  echo "${tag#v}"
}

if [ -z "$ROBOT_ID" ]; then
  echo "ROBOT_ID is required."
  echo "Example:"
  echo "  ROBOT_ID=wctestid curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | bash"
  exit 1
fi

VER="$(resolve_version)"
URL="https://github.com/${REPO}/releases/download/v${VER}/openclaw-worktool-${VER}.tgz"

echo "Downloading plugin package ${VER} from ${REPO}..."
curl -fsSL "$URL" -o "$ARCHIVE_PATH"

echo "Extracting release package..."
tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"
PLUGIN_DIR="$TMP_DIR/package"

if [ ! -d "$PLUGIN_DIR" ]; then
  echo "Failed to locate extracted plugin package directory."
  exit 1
fi

echo "Installing with OpenClaw..."
openclaw plugins install "$PLUGIN_DIR"

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required to patch ${OPENCLAW_CONFIG} automatically."
  echo "Plugin installed, but config not updated."
  exit 1
fi

if [ ! -f "$OPENCLAW_CONFIG" ]; then
  echo "Config file not found: $OPENCLAW_CONFIG"
  echo "Please run OpenClaw once to initialize config, then rerun installer."
  exit 1
fi

echo "Patching OpenClaw config: $OPENCLAW_CONFIG"
node - <<'NODE'
const fs = require("fs");

const path = process.env.OPENCLAW_CONFIG;
const robotId = process.env.ROBOT_ID;
const bridgeBaseUrl = process.env.BRIDGE_BASE_URL;
const webhookHost = process.env.WEBHOOK_HOST;
const webhookPort = Number(process.env.WEBHOOK_PORT || "18799");
const webhookPath = process.env.WEBHOOK_PATH || "/wechat/webhook";

const cfg = JSON.parse(fs.readFileSync(path, "utf8"));
cfg.plugins = cfg.plugins || {};
cfg.plugins.entries = cfg.plugins.entries || {};
cfg.plugins.entries.worktool = cfg.plugins.entries.worktool || { enabled: true, config: {} };
cfg.plugins.entries.worktool.enabled = true;
cfg.plugins.installs = cfg.plugins.installs || {};
cfg.plugins.installs.worktool = cfg.plugins.installs.worktool || { source: "npm" };
cfg.plugins.allow = Array.isArray(cfg.plugins.allow) ? cfg.plugins.allow : [];
if (!cfg.plugins.allow.includes("worktool")) cfg.plugins.allow.push("worktool");

cfg.channels = cfg.channels || {};
cfg.channels.worktool = cfg.channels.worktool || {};
cfg.channels.worktool.enabled = true;
cfg.channels.worktool.robotId = robotId;
cfg.channels.worktool.bridgeBaseUrl = bridgeBaseUrl;
cfg.channels.worktool.webhookHost = webhookHost;
cfg.channels.worktool.webhookPort = webhookPort;
cfg.channels.worktool.webhookPath = webhookPath;

fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
NODE

echo "Done."
echo "Configured channels.worktool:"
echo "  robotId=${ROBOT_ID}"
echo "  bridgeBaseUrl=${BRIDGE_BASE_URL}"
echo "  webhook=${WEBHOOK_HOST}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
echo ""
echo "Next:"
echo "1) Ensure upstream callback points to your public URL ending with ${WEBHOOK_PATH}"
echo "2) Send token via header x-worktool-token=${ROBOT_ID} or query ?robotId=${ROBOT_ID}"
