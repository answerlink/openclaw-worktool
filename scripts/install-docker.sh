#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-answerlink/openclaw-plugin-worktool}"
VERSION="${VERSION:-latest}" # e.g. 0.2.1 or latest

# Core WorkTool channel settings
ROBOT_ID="${ROBOT_ID:-}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
BRIDGE_BASE_URL="${BRIDGE_BASE_URL:-https://api.worktool.ymdyes.cn}"
WEBHOOK_HOST="${WEBHOOK_HOST:-0.0.0.0}"
WEBHOOK_PORT="${WEBHOOK_PORT:-18799}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/wechat/webhook}"

# Model settings written to .env for docker-compose
MODEL_ID="${MODEL_ID:-claw-primary}"
MODEL_BASE_URL="${MODEL_BASE_URL:-}"
MODEL_API_KEY="${MODEL_API_KEY:-}"
MODEL_API_PROTOCOL="${MODEL_API_PROTOCOL:-openai-completions}"

# Docker/OpenClaw project paths
ENV_FILE="${ENV_FILE:-./.env}"
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

has_tty() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

load_env_file() {
  [ -f "$ENV_FILE" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    case "$line" in
      ''|'#'*)
        continue
        ;;
    esac
    if [[ "$line" != *=* ]]; then
      continue
    fi
    key="${line%%=*}"
    val="${line#*=}"
    key="${key## }"
    key="${key%% }"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      continue
    fi
    if [ "${val#\"}" != "$val" ] && [ "${val%\"}" != "$val" ]; then
      val="${val#\"}"
      val="${val%\"}"
    elif [ "${val#\'}" != "$val" ] && [ "${val%\'}" != "$val" ]; then
      val="${val#\'}"
      val="${val%\'}"
    fi
    if [ -z "${!key:-}" ]; then
      printf -v "$key" '%s' "$val"
      export "$key"
    fi
  done < "$ENV_FILE"
}

prompt_value() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local secret="${4:-0}"
  local current_value="${!var_name:-}"
  local answer=""

  if [ -n "$current_value" ]; then
    return 0
  fi

  if ! has_tty; then
    return 1
  fi

  if [ "$secret" = "1" ]; then
    if [ -n "$default_value" ]; then
      printf "%s [***]: " "$prompt_text" > /dev/tty
    else
      printf "%s: " "$prompt_text" > /dev/tty
    fi
    IFS= read -r -s answer < /dev/tty
    printf "\n" > /dev/tty
  else
    if [ -n "$default_value" ]; then
      printf "%s [%s]: " "$prompt_text" "$default_value" > /dev/tty
    else
      printf "%s: " "$prompt_text" > /dev/tty
    fi
    IFS= read -r answer < /dev/tty
  fi

  if [ -z "$answer" ]; then
    answer="$default_value"
  fi

  if [ -n "$answer" ]; then
    printf -v "$var_name" '%s' "$answer"
    export "$var_name"
    return 0
  fi

  return 1
}

upsert_env() {
  local key="$1"
  local value="$2"
  mkdir -p "$(dirname "$ENV_FILE")"
  [ -f "$ENV_FILE" ] || touch "$ENV_FILE"

  local escaped
  escaped="$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')"

  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i.bak "s/^${key}=.*/${key}=${escaped}/" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
  else
    printf "%s=%s\n" "$key" "$value" >> "$ENV_FILE"
  fi
}

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

load_env_file

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required."
  exit 1
fi

MISSING=()

if [ -z "$ROBOT_ID" ] && ! prompt_value ROBOT_ID "WorkTool robotId" "" 0; then
  MISSING+=("ROBOT_ID")
fi

if [ -z "$PUBLIC_BASE_URL" ] && ! prompt_value PUBLIC_BASE_URL "Public callback base URL (e.g. https://your-domain.com)" "" 0; then
  MISSING+=("PUBLIC_BASE_URL")
fi

if [ -z "$MODEL_BASE_URL" ] && ! prompt_value MODEL_BASE_URL "Model base URL (e.g. http://127.0.0.1:13030/v1)" "" 0; then
  MISSING+=("MODEL_BASE_URL")
fi

if [ -z "$MODEL_API_KEY" ] && ! prompt_value MODEL_API_KEY "Model API key" "dummy_key" 1; then
  MISSING+=("MODEL_API_KEY")
fi

if [ -z "$MODEL_ID" ] && ! prompt_value MODEL_ID "Model ID" "claw-primary" 0; then
  MISSING+=("MODEL_ID")
fi

if [ -z "$MODEL_API_PROTOCOL" ] && ! prompt_value MODEL_API_PROTOCOL "Model API protocol" "openai-completions" 0; then
  MISSING+=("MODEL_API_PROTOCOL")
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "Missing required variables: ${MISSING[*]}"
  echo "Set them in environment or ${ENV_FILE}, then rerun."
  exit 1
fi

if [ ! -f "$OPENCLAW_CONFIG" ]; then
  if has_tty; then
    prompt_value OPENCLAW_CONFIG "Path to openclaw.json" "$OPENCLAW_CONFIG" 0 || true
  fi
fi

if [ ! -f "$OPENCLAW_CONFIG" ]; then
  echo "OpenClaw config not found: $OPENCLAW_CONFIG"
  echo "Please run this script in your OpenClaw docker project directory"
  echo "or set OPENCLAW_CONFIG=/path/to/runtime/config/openclaw.json"
  exit 1
fi

# Persist collected variables for future reruns.
upsert_env MODEL_ID "$MODEL_ID"
upsert_env MODEL_BASE_URL "$MODEL_BASE_URL"
upsert_env MODEL_API_KEY "$MODEL_API_KEY"
upsert_env MODEL_API_PROTOCOL "$MODEL_API_PROTOCOL"
upsert_env ROBOT_ID "$ROBOT_ID"
upsert_env PUBLIC_BASE_URL "$PUBLIC_BASE_URL"
upsert_env BRIDGE_BASE_URL "$BRIDGE_BASE_URL"
upsert_env WEBHOOK_HOST "$WEBHOOK_HOST"
upsert_env WEBHOOK_PORT "$WEBHOOK_PORT"
upsert_env WEBHOOK_PATH "$WEBHOOK_PATH"

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

callback_url="${PUBLIC_BASE_URL%/}${WEBHOOK_PATH}"

echo "Done (docker one-line mode)."
echo "Configured channels.worktool:"
echo "  robotId=${ROBOT_ID}"
echo "  bridgeBaseUrl=${BRIDGE_BASE_URL}"
echo "  webhookBind=${WEBHOOK_HOST}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
echo "  plugin.sourcePath=${CONTAINER_PLUGIN_PATH}"
echo "  envFile=${ENV_FILE}"
echo ""
echo "WorkTool upstream callback URL:"
echo "  ${callback_url}"
