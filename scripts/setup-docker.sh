#!/usr/bin/env bash
set -euo pipefail

# ── Defaults ────────────────────────────────────────────
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-alpine/openclaw:2026.3.28}"
CONTAINER_NAME="${CONTAINER_NAME:-openclaw-gateway}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
ROBOT_ID="${ROBOT_ID:-}"
BRIDGE_BASE_URL="${BRIDGE_BASE_URL:-https://api.worktool.ymdyes.cn}"
WEBHOOK_HOST="${WEBHOOK_HOST:-0.0.0.0}"
WEBHOOK_PORT="${WEBHOOK_PORT:-18799}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/wechat/webhook}"
ENV_FILE="${ENV_FILE:-./.env}"
CONTAINER_PLUGIN_PATH="/app/extensions/worktool"
HEALTH_WAIT="${HEALTH_WAIT:-30}"
SKIP_ONBOARD="${SKIP_ONBOARD:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SOURCE_DIR="${PLUGIN_SOURCE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Detect openclaw home (works on Windows Git Bash + Linux/macOS)
OPENCLAW_HOME="${OPENCLAW_HOME:-${USERPROFILE:-$HOME}/.openclaw}"

# ── .env loading ────────────────────────────────────────
load_env_file() {
  [ -f "$ENV_FILE" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key## }"; key="${key%% }"
    [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && continue
    if [ "${val#\"}" != "$val" ] && [ "${val%\"}" != "$val" ]; then
      val="${val#\"}"; val="${val%\"}"
    elif [ "${val#\'}" != "$val" ] && [ "${val%\'}" != "$val" ]; then
      val="${val#\'}"; val="${val%\'}"
    fi
    [ -z "${!key:-}" ] && printf -v "$key" '%s' "$val" && export "$key" || true
  done < "$ENV_FILE"
  return 0
}

# ── Interactive prompts ─────────────────────────────────
has_tty() { [ -r /dev/tty ] && [ -w /dev/tty ]; }

prompt_value() {
  local var_name="$1" prompt_text="$2" default_value="${3:-}"
  local current_value="${!var_name:-}"
  [ -n "$current_value" ] && return 0
  has_tty || return 1
  if [ -n "$default_value" ]; then
    printf "  %s [%s]: " "$prompt_text" "$default_value" > /dev/tty
  else
    printf "  %s: " "$prompt_text" > /dev/tty
  fi
  local answer; IFS= read -r answer < /dev/tty
  [ -z "$answer" ] && answer="$default_value"
  answer="${answer## }"; answer="${answer%% }"
  if [ -n "$answer" ]; then
    printf -v "$var_name" '%s' "$answer"; export "$var_name"; return 0
  fi
  return 1
}

prompt_yn() {
  local prompt_text="$1" default="${2:-y}"
  has_tty || { [ "$default" = "y" ] && return 0 || return 1; }
  local hint="Y/n"; [ "$default" = "n" ] && hint="y/N"
  printf "  %s [%s]: " "$prompt_text" "$hint" > /dev/tty
  local answer; IFS= read -r answer < /dev/tty
  answer="${answer:-$default}"
  case "${answer,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

# ── .env persistence ────────────────────────────────────
upsert_env() {
  local key="$1" value="$2"
  mkdir -p "$(dirname "$ENV_FILE")"
  [ -f "$ENV_FILE" ] || touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    local escaped; escaped="$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')"
    sed -i.bak "s/^${key}=.*/${key}=${escaped}/" "$ENV_FILE"; rm -f "${ENV_FILE}.bak"
  else
    printf "%s=%s\n" "$key" "$value" >> "$ENV_FILE"
  fi
}

# ── Preflight ───────────────────────────────────────────
if [ ! -f "$PLUGIN_SOURCE_DIR/openclaw.plugin.json" ]; then
  echo "Cannot find openclaw.plugin.json in $PLUGIN_SOURCE_DIR"
  echo "Run this script from the plugin repo root, or set PLUGIN_SOURCE_DIR."
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found."
  echo ""
  echo "Install Docker Desktop:"
  echo "  Windows : https://docs.docker.com/desktop/install/windows-install/"
  echo "  macOS   : https://docs.docker.com/desktop/install/mac-install/"
  echo "  Linux   : https://docs.docker.com/engine/install/"
  exit 1
fi

# ── Environment pre-check ───────────────────────────────
echo ""
echo "-- Pre-check: existing OpenClaw environment --"
echo ""

PRECHECK_WARN=0

# 1) Check existing openclaw containers
EXISTING_CONTAINERS="$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | grep -i 'openclaw' || true)"
if [ -n "$EXISTING_CONTAINERS" ]; then
  echo "  ⚠️  Found existing OpenClaw container(s):"
  echo "$EXISTING_CONTAINERS" | while IFS=$'\t' read -r name image status; do
    echo "     - $name  ($image)  [$status]"
    if [ "$image" != "$OPENCLAW_IMAGE" ]; then
      echo "       ↳ Version mismatch! This script will install: $OPENCLAW_IMAGE"
    fi
  done
  PRECHECK_WARN=1
fi

# 2) Check ~/.openclaw/extensions for third-party plugins
if [ -d "$OPENCLAW_HOME/extensions" ]; then
  EXT_LIST="$(ls "$OPENCLAW_HOME/extensions" 2>/dev/null | grep -v '^worktool$' || true)"
  if [ -n "$EXT_LIST" ]; then
    echo "  ⚠️  Found third-party plugins in $OPENCLAW_HOME/extensions:"
    echo "$EXT_LIST" | while read -r ext; do
      echo "     - $ext"
    done
    echo "     These plugins may be incompatible with $OPENCLAW_IMAGE and cause startup failures."
    PRECHECK_WARN=1
  fi
fi

# 3) If warnings found, let user decide
if [ "$PRECHECK_WARN" = "1" ] && has_tty; then
  echo ""
  echo "  Options:"
  echo "    [1] Continue anyway (existing plugins stay, may cause issues)"
  echo "    [2] Backup & hide incompatible plugins (move extensions to extensions.bak)"
  echo "    [3] Full clean reset (remove container + ~/.openclaw, start fresh)"
  echo "    [4] Abort"
  echo ""
  printf "  Your choice [1/2/3/4]: " > /dev/tty
  CHOICE=""; IFS= read -r CHOICE < /dev/tty
  CHOICE="${CHOICE## }"; CHOICE="${CHOICE%% }"

  case "$CHOICE" in
    1)
      echo "  Continuing with existing environment..."
      ;;
    2)
      echo "  Backing up extensions..."
      if [ -d "$OPENCLAW_HOME/extensions" ]; then
        mv "$OPENCLAW_HOME/extensions" "$OPENCLAW_HOME/extensions.bak.$(date +%Y%m%d%H%M%S)"
        echo "  Extensions moved to extensions.bak.*"
      fi
      if [ -n "$EXISTING_CONTAINERS" ]; then
        CONTAINER_TO_STOP="$(docker ps -a --format '{{.Names}}' | grep -i 'openclaw' | head -1 || true)"
        if [ -n "$CONTAINER_TO_STOP" ]; then
          docker stop "$CONTAINER_TO_STOP" >/dev/null 2>&1 || true
          docker rm "$CONTAINER_TO_STOP" >/dev/null 2>&1 || true
          echo "  Old container removed."
        fi
      fi
      ;;
    3)
      echo "  Full clean reset..."
      docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i 'openclaw' | while read -r c; do
        docker stop "$c" >/dev/null 2>&1 || true
        docker rm "$c" >/dev/null 2>&1 || true
        echo "  Removed container: $c"
      done
      if [ -d "$OPENCLAW_HOME" ]; then
        rm -rf "$OPENCLAW_HOME"
        echo "  ~/.openclaw deleted."
      fi
      ;;
    4|*)
      echo "  Aborted."
      exit 0
      ;;
  esac
  echo ""
elif [ "$PRECHECK_WARN" = "0" ]; then
  echo "  No conflicts detected. Proceeding..."
  echo ""
fi

# ── Main ────────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  OpenClaw + WorkTool Plugin - Docker Setup"
echo "=============================================="
echo ""

load_env_file

# ── Phase 1: Collect WorkTool config ───────────────────
echo "-- WorkTool plugin config --"
echo ""
prompt_value ROBOT_ID        "WorkTool Robot ID"    "" || {
  echo ""; echo "ROBOT_ID is required. Set it in .env or pass as env var."; exit 1
}
prompt_value BRIDGE_BASE_URL "Bridge URL"           "https://api.worktool.ymdyes.cn"
prompt_value WEBHOOK_PORT    "Webhook port"         "18799"
prompt_value CONTAINER_NAME  "Container name"       "openclaw-gateway"
prompt_value OPENCLAW_IMAGE  "OpenClaw image"       "alpine/openclaw:2026.3.28"
prompt_value GATEWAY_PORT    "Gateway port"         "18789"

upsert_env OPENCLAW_IMAGE   "$OPENCLAW_IMAGE"
upsert_env CONTAINER_NAME   "$CONTAINER_NAME"
upsert_env GATEWAY_PORT     "$GATEWAY_PORT"
upsert_env ROBOT_ID         "$ROBOT_ID"
upsert_env BRIDGE_BASE_URL  "$BRIDGE_BASE_URL"
upsert_env WEBHOOK_HOST     "$WEBHOOK_HOST"
upsert_env WEBHOOK_PORT     "$WEBHOOK_PORT"
upsert_env WEBHOOK_PATH     "$WEBHOOK_PATH"

echo ""
echo "  Image     : $OPENCLAW_IMAGE"
echo "  Container : $CONTAINER_NAME"
echo "  Robot ID  : $ROBOT_ID"
echo "  Bridge    : $BRIDGE_BASE_URL"
echo "  Gateway   : 0.0.0.0:$GATEWAY_PORT"
echo "  Webhook   : $WEBHOOK_HOST:$WEBHOOK_PORT$WEBHOOK_PATH"
echo ""

# ── Phase 2: Ensure image exists ──────────────────────
STEP=0
TOTAL=9

STEP=$((STEP+1))
echo "[$STEP/$TOTAL] Checking Docker image..."
if docker image inspect "$OPENCLAW_IMAGE" >/dev/null 2>&1; then
  echo "  Image $OPENCLAW_IMAGE found locally."
else
  echo "  Pulling $OPENCLAW_IMAGE ..."
  docker pull "$OPENCLAW_IMAGE"
fi

# ── Phase 3: Create or reuse container ─────────────────
STEP=$((STEP+1))
echo "[$STEP/$TOTAL] Preparing container..."

NEED_CREATE=0
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "  Container '$CONTAINER_NAME' already exists."
  STATUS="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")"
  if [ "$STATUS" = "restarting" ]; then
    echo "  Container is in a restart loop, stopping..."
    docker update --restart no "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
else
  NEED_CREATE=1
fi

if [ "$NEED_CREATE" = "1" ]; then
  echo "  Creating container '$CONTAINER_NAME'..."
  mkdir -p "$OPENCLAW_HOME"
  chmod 777 "$OPENCLAW_HOME"
  docker create \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${GATEWAY_PORT}:${GATEWAY_PORT}" \
    -p "$((GATEWAY_PORT+1)):$((GATEWAY_PORT+1))" \
    -p "${WEBHOOK_PORT}:${WEBHOOK_PORT}" \
    -v "${OPENCLAW_HOME}:/home/node/.openclaw:rw" \
    -e "TZ=Asia/Shanghai" \
    "$OPENCLAW_IMAGE" \
    node dist/index.js gateway --bind lan --port "$GATEWAY_PORT"
  echo "  Container created."
fi

# ── Phase 4: Run onboard (model + gateway config) ─────
STEP=$((STEP+1))
echo "[$STEP/$TOTAL] OpenClaw onboard (model & gateway config)..."

RUN_ONBOARD=0
if [ -n "$SKIP_ONBOARD" ]; then
  echo "  SKIP_ONBOARD set, skipping."
elif [ -f "$OPENCLAW_HOME/openclaw.json" ]; then
  if prompt_yn "openclaw.json already exists. Re-run onboard to change model/gateway?" "n"; then
    RUN_ONBOARD=1
  else
    echo "  Keeping existing config."
  fi
else
  RUN_ONBOARD=1
fi

if [ "$RUN_ONBOARD" = "1" ]; then
  mkdir -p "$OPENCLAW_HOME"
  chmod 777 "$OPENCLAW_HOME"
  echo ""
  echo "  Launching OpenClaw onboard..."
  echo "  (Select your model provider, gateway bind, auth token, etc.)"
  echo "  ───────────────────────────────────────────────"
  docker run --rm -it \
    -v "${OPENCLAW_HOME}:/home/node/.openclaw" \
    "$OPENCLAW_IMAGE" \
    node dist/index.js onboard --mode local --no-install-daemon || {
      echo ""
      echo "  Onboard exited with an error."
      echo "  You can re-run this script later; it will pick up where it left off."
      exit 1
    }
  echo "  ───────────────────────────────────────────────"
  echo "  Onboard complete."
fi

# ── Phase 5: Start container so we can exec into it ───
STEP=$((STEP+1))
echo "[$STEP/$TOTAL] Starting container..."

STATUS="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")"
if [ "$STATUS" != "running" ]; then
  docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
  sleep 3
fi

# ── Phase 6: Copy plugin source into container ────────
STEP=$((STEP+1))
echo "[$STEP/$TOTAL] Copying plugin files into container..."
docker exec -u root "$CONTAINER_NAME" mkdir -p "$CONTAINER_PLUGIN_PATH"
docker cp "$PLUGIN_SOURCE_DIR/index.js"             "$CONTAINER_NAME:$CONTAINER_PLUGIN_PATH/index.js"
docker cp "$PLUGIN_SOURCE_DIR/openclaw.plugin.json"  "$CONTAINER_NAME:$CONTAINER_PLUGIN_PATH/openclaw.plugin.json"
docker cp "$PLUGIN_SOURCE_DIR/package.json"          "$CONTAINER_NAME:$CONTAINER_PLUGIN_PATH/package.json"
docker cp "$PLUGIN_SOURCE_DIR/src"                   "$CONTAINER_NAME:$CONTAINER_PLUGIN_PATH/src"

# ── Phase 7: SDK shim + compatibility patches ─────────
STEP=$((STEP+1))
echo "[$STEP/$TOTAL] Creating SDK shim & patching compatibility..."

docker exec -u root "$CONTAINER_NAME" sh -c "chmod -R 755 $CONTAINER_PLUGIN_PATH"

docker exec -u root "$CONTAINER_NAME" sh -c "\
  mkdir -p $CONTAINER_PLUGIN_PATH/node_modules/openclaw/plugin-sdk && \
  cp -a /app/dist/plugin-sdk/* $CONTAINER_PLUGIN_PATH/node_modules/openclaw/plugin-sdk/"

docker exec -u root "$CONTAINER_NAME" node -e "\
  require('fs').writeFileSync(\
    '$CONTAINER_PLUGIN_PATH/node_modules/openclaw/package.json',\
    JSON.stringify({name:'openclaw',type:'module',exports:{\
      './plugin-sdk':'./plugin-sdk/index.js',\
      './plugin-sdk/*':'./plugin-sdk/*'\
    }},null,2))"

docker exec -u root "$CONTAINER_NAME" node -e "\
  const fs=require('fs');\
  let ch=fs.readFileSync('$CONTAINER_PLUGIN_PATH/src/channel.js','utf8');\
  if(/import\\s*\\{[^}]*DEFAULT_ACCOUNT_ID/.test(ch)){\
    ch=ch.replace(\
      /import\\s*\\{[^}]*DEFAULT_ACCOUNT_ID[^}]*\\}\\s*from\\s*['\x22]openclaw\\/plugin-sdk['\x22];?/,\
      'const DEFAULT_ACCOUNT_ID = \x22default\x22;');\
    fs.writeFileSync('$CONTAINER_PLUGIN_PATH/src/channel.js',ch);\
    console.log('  channel.js: DEFAULT_ACCOUNT_ID patched');\
  }else{console.log('  channel.js: already patched');}\
  let ib=fs.readFileSync('$CONTAINER_PLUGIN_PATH/src/inbound.js','utf8');\
  if(/import\\s*\\{[^}]*createReplyPrefixContext/.test(ib)){\
    ib=ib.replace(\
      /import\\s*\\{[^}]*createReplyPrefixContext[^}]*\\}\\s*from\\s*['\x22]openclaw\\/plugin-sdk['\x22];?/,\
      'function createReplyPrefixContext({cfg,agentId}){return{responsePrefix:undefined,responsePrefixContextProvider:undefined};}');\
    fs.writeFileSync('$CONTAINER_PLUGIN_PATH/src/inbound.js',ib);\
    console.log('  inbound.js: createReplyPrefixContext patched');\
  }else{console.log('  inbound.js: already patched');}"

docker exec -u root "$CONTAINER_NAME" sh -c "chown -R node:node $CONTAINER_PLUGIN_PATH"

# ── Phase 8: Write worktool config into openclaw.json ──
STEP=$((STEP+1))
echo "[$STEP/$TOTAL] Writing WorkTool channel config..."

PUBLIC_IP="$(curl -fsS --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")"

docker exec -u root \
  -e "PLUGIN_PATH=$CONTAINER_PLUGIN_PATH" \
  -e "ROBOT_ID=$ROBOT_ID" \
  -e "BRIDGE_BASE_URL=$BRIDGE_BASE_URL" \
  -e "WEBHOOK_HOST=$WEBHOOK_HOST" \
  -e "WEBHOOK_PORT=$WEBHOOK_PORT" \
  -e "WEBHOOK_PATH=$WEBHOOK_PATH" \
  -e "GATEWAY_PORT=$GATEWAY_PORT" \
  -e "PUBLIC_IP=$PUBLIC_IP" \
  "$CONTAINER_NAME" node -e '
  var fs=require("fs");
  var p="/home/node/.openclaw/openclaw.json";
  if(!fs.existsSync(p)){console.error("openclaw.json not found at "+p);process.exit(1);}
  var cfg=JSON.parse(fs.readFileSync(p,"utf8"));
  cfg.plugins=cfg.plugins||{};
  cfg.plugins.entries=cfg.plugins.entries||{};
  cfg.plugins.entries.worktool={enabled:true,config:{}};
  cfg.plugins.installs=cfg.plugins.installs||{};
  cfg.plugins.installs.worktool={source:"path",sourcePath:process.env.PLUGIN_PATH};
  cfg.plugins.allow=Array.isArray(cfg.plugins.allow)?cfg.plugins.allow:[];
  if(cfg.plugins.allow.indexOf("worktool")<0)cfg.plugins.allow.push("worktool");
  cfg.channels=cfg.channels||{};
  cfg.channels.worktool={
    enabled:true,
    robotId:process.env.ROBOT_ID,
    bridgeBaseUrl:process.env.BRIDGE_BASE_URL,
    webhookHost:process.env.WEBHOOK_HOST,
    webhookPort:Number(process.env.WEBHOOK_PORT),
    webhookPath:process.env.WEBHOOK_PATH
  };
  var gw=cfg.gateway=cfg.gateway||{};
  gw.controlUi=gw.controlUi||{};
  gw.controlUi.allowInsecureAuth=true;
  gw.controlUi.dangerouslyDisableDeviceAuth=true;
  var o=gw.controlUi.allowedOrigins||[];
  var gp=process.env.GATEWAY_PORT;
  ["http://127.0.0.1:"+gp,"http://localhost:"+gp].forEach(function(u){if(o.indexOf(u)<0)o.push(u)});
  var pub=process.env.PUBLIC_IP;
  if(pub){var pu="http://"+pub+":"+gp;if(o.indexOf(pu)<0)o.push(pu);}
  gw.controlUi.allowedOrigins=o;
  fs.writeFileSync(p,JSON.stringify(cfg,null,2));
  console.log("  openclaw.json updated");
  if(pub)console.log("  public access: http://"+pub+":"+gp);
'

# ── Phase 9: Restart & verify ─────────────────────────
STEP=$((STEP+1))
echo "[$STEP/$TOTAL] Restarting container & verifying..."

docker update --restart unless-stopped "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker restart "$CONTAINER_NAME"

echo "  Waiting for webhook (${HEALTH_WAIT}s)..."
OK=0
for i in $(seq 1 $((HEALTH_WAIT / 3))); do
  sleep 3
  result="$(curl -fsS "http://127.0.0.1:${WEBHOOK_PORT}${WEBHOOK_PATH}" 2>&1 || true)"
  if echo "$result" | grep -q "worktool"; then
    OK=1; break
  fi
done

echo ""
echo "=============================================="
if [ "$OK" = "1" ]; then
  echo "  Setup complete!"
  echo "=============================================="
  echo ""
  echo "  Webhook : $result"
  echo "  Gateway : http://127.0.0.1:$GATEWAY_PORT"
  if [ -n "$PUBLIC_IP" ]; then
    echo "  Public  : http://$PUBLIC_IP:$GATEWAY_PORT"
  fi
else
  echo "  Plugin installed. Webhook still starting up..."
  echo "=============================================="
  echo ""
  echo "  Check logs: docker logs --tail 30 $CONTAINER_NAME"
fi

echo ""
if [ -n "$PUBLIC_IP" ]; then
  echo "  Next step: set callback URL in WorkTool dashboard:"
  echo "    http://$PUBLIC_IP:$WEBHOOK_PORT$WEBHOOK_PATH?robotId=$ROBOT_ID"
else
  echo "  Next step: set callback URL in WorkTool dashboard:"
  echo "    https://<your-public-domain>$WEBHOOK_PATH?robotId=$ROBOT_ID"
fi
echo ""
echo "  Config saved to $ENV_FILE (rerun script to upgrade/reconfigure)."
echo ""
