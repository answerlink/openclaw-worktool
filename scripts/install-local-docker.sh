#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROBOT_ID="${ROBOT_ID:-}"
BRIDGE_BASE_URL="${BRIDGE_BASE_URL:-https://api.worktool.ymdyes.cn}"
WEBHOOK_HOST="${WEBHOOK_HOST:-0.0.0.0}"
WEBHOOK_PORT="${WEBHOOK_PORT:-18799}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/wechat/webhook}"

OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-$ROOT_DIR/../runtime/config/openclaw.json}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/../docker-compose.worktool.yml}"
SERVICE_NAME="${SERVICE_NAME:-openclaw-worktool}"
CONTAINER_PLUGIN_PATH="${CONTAINER_PLUGIN_PATH:-/app/extensions/worktool}"
AUTO_RESTART="${AUTO_RESTART:-1}"

if [ -z "$ROBOT_ID" ]; then
  echo "ROBOT_ID is required."
  echo "Example:"
  echo "  ROBOT_ID=wctestid bash scripts/install-local-docker.sh"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required."
  exit 1
fi

if [ ! -f "$OPENCLAW_CONFIG" ]; then
  echo "OpenClaw config not found: $OPENCLAW_CONFIG"
  echo "Set OPENCLAW_CONFIG to your docker-mounted openclaw.json and retry."
  exit 1
fi

echo "Patching docker OpenClaw config: $OPENCLAW_CONFIG"
export OPENCLAW_CONFIG ROBOT_ID BRIDGE_BASE_URL WEBHOOK_HOST WEBHOOK_PORT WEBHOOK_PATH CONTAINER_PLUGIN_PATH
node - <<'NODE'
const fs = require("fs");
const path = process.env.OPENCLAW_CONFIG;
const robotId = process.env.ROBOT_ID;
const bridgeBaseUrl = process.env.BRIDGE_BASE_URL;
const webhookHost = process.env.WEBHOOK_HOST;
const webhookPort = Number(process.env.WEBHOOK_PORT || "18799");
const webhookPath = process.env.WEBHOOK_PATH || "/wechat/webhook";
const sourcePath = process.env.CONTAINER_PLUGIN_PATH || "/app/extensions/worktool";

const cfg = JSON.parse(fs.readFileSync(path, "utf8"));
cfg.plugins = cfg.plugins || {};
cfg.plugins.entries = cfg.plugins.entries || {};
cfg.plugins.entries.worktool = cfg.plugins.entries.worktool || { enabled: true, config: {} };
cfg.plugins.entries.worktool.enabled = true;
cfg.plugins.installs = cfg.plugins.installs || {};
cfg.plugins.installs.worktool = { source: "path", sourcePath };
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

compose_restart() {
  if [ "$AUTO_RESTART" = "0" ]; then
    echo "AUTO_RESTART=0, skip restarting docker service."
    return 0
  fi
  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Compose file not found: $COMPOSE_FILE"
    echo "Config saved. Please restart container manually."
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "Restarting docker service with docker-compose..."
    docker-compose -f "$COMPOSE_FILE" restart "$SERVICE_NAME"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "Restarting docker service with docker compose..."
    docker compose -f "$COMPOSE_FILE" restart "$SERVICE_NAME"
    return 0
  fi
  echo "docker compose not found. Please restart container manually."
}

compose_restart

echo "Done (docker mode)."
echo "Configured channels.worktool:"
echo "  robotId=${ROBOT_ID}"
echo "  bridgeBaseUrl=${BRIDGE_BASE_URL}"
echo "  webhook=${WEBHOOK_HOST}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
echo "  plugin.sourcePath=${CONTAINER_PLUGIN_PATH}"
