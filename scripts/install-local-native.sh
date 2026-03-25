#!/usr/bin/env bash
set -euo pipefail

if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw CLI not found in PATH."
  echo "Install OpenClaw first, then re-run this script."
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROBOT_ID="${ROBOT_ID:-}"
BRIDGE_BASE_URL="${BRIDGE_BASE_URL:-https://api.worktool.ymdyes.cn}"
WEBHOOK_HOST="${WEBHOOK_HOST:-0.0.0.0}"
WEBHOOK_PORT="${WEBHOOK_PORT:-18799}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/wechat/webhook}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"

if [ -z "$ROBOT_ID" ]; then
  echo "ROBOT_ID is required."
  echo "Example:"
  echo "  ROBOT_ID=wc11a bash scripts/install-local-native.sh"
  exit 1
fi

echo "Installing plugin from local source: $ROOT_DIR"
openclaw plugins install "$ROOT_DIR"

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
export ROBOT_ID BRIDGE_BASE_URL WEBHOOK_HOST WEBHOOK_PORT WEBHOOK_PATH OPENCLAW_CONFIG
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
cfg.plugins.installs.worktool = cfg.plugins.installs.worktool || { source: "path" };
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

echo "Done (native mode)."
echo "Configured channels.worktool:"
echo "  robotId=${ROBOT_ID}"
echo "  bridgeBaseUrl=${BRIDGE_BASE_URL}"
echo "  webhook=${WEBHOOK_HOST}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
echo ""
echo "Next:"
echo "1) Ensure upstream callback points to your public URL ending with ${WEBHOOK_PATH}"
echo "2) Send token via header x-worktool-token=${ROBOT_ID} or query ?robotId=${ROBOT_ID}"
