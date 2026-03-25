#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-answerlink/openclaw-plugin-worktool}"
VERSION="${VERSION:-latest}" # e.g. 0.2.1 or latest
ROBOT_ID="${ROBOT_ID:-}"
BRIDGE_BASE_URL="${BRIDGE_BASE_URL:-https://api.worktool.ymdyes.cn}"
WEBHOOK_HOST="${WEBHOOK_HOST:-0.0.0.0}"
WEBHOOK_PORT="${WEBHOOK_PORT:-18799}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/wechat/webhook}"

COMPOSE_FILE="${COMPOSE_FILE:-./docker-compose.worktool.yml}"
SERVICE_NAME="${SERVICE_NAME:-openclaw-worktool}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-./runtime/config/openclaw.json}"
PLUGIN_HOST_DIR="${PLUGIN_HOST_DIR:-./openclaw-plugin-worktool}"
CONTAINER_PLUGIN_PATH="${CONTAINER_PLUGIN_PATH:-/app/extensions/worktool}"
AUTO_RESTART="${AUTO_RESTART:-1}"

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
  echo "  ROBOT_ID=wc11a curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install-docker.sh | bash"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required."
  exit 1
fi

if [ ! -f "$OPENCLAW_CONFIG" ]; then
  echo "OpenClaw config not found: $OPENCLAW_CONFIG"
  echo "Please run this script in your OpenClaw docker project directory"
  echo "or set OPENCLAW_CONFIG=/path/to/runtime/config/openclaw.json"
  exit 1
fi

VER="$(resolve_version)"
URL="https://github.com/${REPO}/releases/download/v${VER}/openclaw-plugin-worktool-${VER}.tgz"

echo "Downloading plugin package ${VER} from ${REPO}..."
curl -fsSL "$URL" -o "$ARCHIVE_PATH"
tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"
PKG_DIR="$TMP_DIR/package"

if [ ! -d "$PKG_DIR" ]; then
  echo "Failed to locate extracted package directory."
  exit 1
fi

echo "Syncing package to host plugin directory: $PLUGIN_HOST_DIR"
mkdir -p "$PLUGIN_HOST_DIR"
cp -a "$PKG_DIR"/. "$PLUGIN_HOST_DIR"/

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

restart_compose() {
  if [ "$AUTO_RESTART" = "0" ]; then
    echo "AUTO_RESTART=0, skip restarting docker service."
    return 0
  fi

  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Compose file not found: $COMPOSE_FILE"
    echo "Config saved. Please restart your OpenClaw container manually."
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

  echo "docker compose not found. Please restart your OpenClaw container manually."
}

restart_compose

echo "Done (docker one-line mode)."
echo "Configured channels.worktool:"
echo "  robotId=${ROBOT_ID}"
echo "  bridgeBaseUrl=${BRIDGE_BASE_URL}"
echo "  webhook=${WEBHOOK_HOST}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
echo "  plugin.sourcePath=${CONTAINER_PLUGIN_PATH}"
