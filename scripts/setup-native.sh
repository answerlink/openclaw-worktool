#!/usr/bin/env bash
set -euo pipefail

# ── One-liner for Linux cloud servers (native install, always latest OpenClaw) ──
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-worktool/main/scripts/setup-native.sh -o /tmp/oc-setup.sh; bash /tmp/oc-setup.sh
#
# Non-interactive (CI / repeat installs):
#   ROBOT_ID=xxx SKIP_ONBOARD=1 bash /tmp/oc-setup.sh

REPO="answerlink/openclaw-worktool"
INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw-worktool}"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
WEBHOOK_HOST="${WEBHOOK_HOST:-0.0.0.0}"
WEBHOOK_PORT="${WEBHOOK_PORT:-18799}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/wechat/webhook}"
BRIDGE_BASE_URL="${BRIDGE_BASE_URL:-https://api.worktool.ymdyes.cn}"
ROBOT_ID="${ROBOT_ID:-}"
SKIP_ONBOARD="${SKIP_ONBOARD:-}"
ENV_FILE="${ENV_FILE:-$INSTALL_DIR/.env}"
MIN_MEM_MB="${MIN_MEM_MB:-3500}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
SERVICE_NAME="openclaw-gateway"
HEALTH_WAIT="${HEALTH_WAIT:-30}"

echo ""
echo "=============================================="
echo "  OpenClaw + WorkTool — Native Setup"
echo "  (always installs latest stable OpenClaw)"
echo "=============================================="
echo ""

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
}

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

# ── Step 1: Memory & Swap ────────────────────────────────
TOTAL_MEM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
TOTAL_SWAP_MB="$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

if [ "$TOTAL_MEM_MB" -gt 0 ] && [ "$TOTAL_MEM_MB" -lt "$MIN_MEM_MB" ]; then
  echo "[1] System memory: ${TOTAL_MEM_MB}MB (recommended >= ${MIN_MEM_MB}MB)"
  if [ "$TOTAL_SWAP_MB" -lt 1024 ]; then
    echo "    Swap: ${TOTAL_SWAP_MB}MB — adding ${SWAP_SIZE}..."
    if [ ! -f /swapfile ]; then
      fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null \
        || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      echo "    Swap enabled."
    else
      swapon /swapfile 2>/dev/null || true
      echo "    Swap file already exists, activated."
    fi
  else
    echo "    Swap: ${TOTAL_SWAP_MB}MB — OK."
  fi
  echo ""
else
  echo "[1] Memory: ${TOTAL_MEM_MB}MB — OK."
fi

# ── Step 2: Install / Upgrade OpenClaw (latest stable) ──
echo "[2] Installing latest stable OpenClaw via official installer..."
echo "    (curl -fsSL https://openclaw.ai/install.sh | bash)"
echo ""

curl -fsSL https://openclaw.ai/install.sh | bash

# Reload PATH — official installer may add to ~/.local/bin or ~/.npm-global/bin
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
hash -r 2>/dev/null || true

# Confirm openclaw is available
if ! command -v openclaw >/dev/null 2>&1; then
  # Try common npm global paths
  for try_path in \
      "$(npm root -g 2>/dev/null)/../../bin" \
      "$HOME/.nvm/versions/node/$(ls $HOME/.nvm/versions/node 2>/dev/null | tail -1)/bin" \
      "/usr/local/bin"; do
    [ -x "$try_path/openclaw" ] && export PATH="$try_path:$PATH" && break
  done
fi

if ! command -v openclaw >/dev/null 2>&1; then
  echo ""
  echo "ERROR: openclaw command not found after install."
  echo "  Try: source ~/.bashrc && openclaw --version"
  echo "  Then re-run this script."
  exit 1
fi

OPENCLAW_VER="$(openclaw --version 2>/dev/null || echo 'unknown')"
echo ""
echo "  OpenClaw version: $OPENCLAW_VER"
echo ""

# ── Step 3: Collect WorkTool config ─────────────────────
echo "[3] WorkTool plugin config..."
mkdir -p "$INSTALL_DIR"
load_env_file

prompt_value ROBOT_ID        "WorkTool Robot ID"    "" || {
  echo ""; echo "ROBOT_ID is required. Set it in .env or pass as env var."; exit 1
}
prompt_value BRIDGE_BASE_URL "Bridge URL"           "https://api.worktool.ymdyes.cn"
prompt_value WEBHOOK_PORT    "Webhook port"         "18799"
prompt_value GATEWAY_PORT    "Gateway port"         "18789"

upsert_env ROBOT_ID         "$ROBOT_ID"
upsert_env BRIDGE_BASE_URL  "$BRIDGE_BASE_URL"
upsert_env WEBHOOK_HOST     "$WEBHOOK_HOST"
upsert_env WEBHOOK_PORT     "$WEBHOOK_PORT"
upsert_env WEBHOOK_PATH     "$WEBHOOK_PATH"
upsert_env GATEWAY_PORT     "$GATEWAY_PORT"

echo ""
echo "  Robot ID  : $ROBOT_ID"
echo "  Bridge    : $BRIDGE_BASE_URL"
echo "  Webhook   : $WEBHOOK_HOST:$WEBHOOK_PORT$WEBHOOK_PATH"
echo "  Gateway   : 0.0.0.0:$GATEWAY_PORT"
echo ""

# ── Step 4: Download plugin source ──────────────────────
echo "[4] Downloading worktool plugin source..."

if [ -f "$INSTALL_DIR/openclaw.plugin.json" ]; then
  echo "  Plugin found at $INSTALL_DIR, updating..."
  if [ -d "$INSTALL_DIR/.git" ]; then
    cd "$INSTALL_DIR"
    git pull --ff-only 2>/dev/null || echo "  git pull failed, using existing files."
  fi
else
  CLONE_OK=0
  if command -v git >/dev/null 2>&1; then
    echo "  Cloning plugin repository..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "https://github.com/${REPO}.git" "$INSTALL_DIR" && CLONE_OK=1 || {
      echo "  git clone failed, trying tarball..."
    }
  fi

  if [ "$CLONE_OK" = "0" ]; then
    echo "  Downloading tarball..."
    TMP_TAR="$(mktemp)"
    rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
    curl -fsSL --connect-timeout 15 \
      "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" -o "$TMP_TAR" 2>/dev/null \
      || curl -fsSL --connect-timeout 15 \
      "https://ghfast.top/https://github.com/${REPO}/archive/refs/heads/main.tar.gz" -o "$TMP_TAR" 2>/dev/null \
      || { echo "Download failed."; exit 1; }
    tar xzf "$TMP_TAR" --strip-components=1 -C "$INSTALL_DIR"
    rm -f "$TMP_TAR"
  fi
fi

cd "$INSTALL_DIR"
[ -f "openclaw.plugin.json" ] || { echo "Plugin source missing. Exiting."; exit 1; }
echo "  Plugin source ready at $INSTALL_DIR"
echo ""

# ── Step 5: Run onboard ─────────────────────────────────
echo "[5] OpenClaw onboard..."

if [ -n "$SKIP_ONBOARD" ]; then
  echo "  SKIP_ONBOARD set, skipping."
elif [ -f "$OPENCLAW_HOME/openclaw.json" ]; then
  echo "  openclaw.json exists, skipping onboard (set SKIP_ONBOARD=0 to force)."
else
  echo "  Starting interactive onboard — choose your model, gateway bind, token..."
  echo "  ──────────────────────────────────────────────────────────────────────"
  openclaw onboard --mode local --no-install-daemon || {
    echo ""
    echo "  Onboard exited with an error. Fix the issue and re-run the script."
    exit 1
  }
  echo "  ──────────────────────────────────────────────────────────────────────"
  echo "  Onboard complete."
fi
echo ""

# ── Step 6: Install plugin into openclaw extensions ─────
echo "[6] Installing worktool plugin..."

PLUGIN_DEST="$OPENCLAW_HOME/extensions/worktool"
mkdir -p "$PLUGIN_DEST"

cp -f "$INSTALL_DIR/index.js"              "$PLUGIN_DEST/index.js"
cp -f "$INSTALL_DIR/openclaw.plugin.json"  "$PLUGIN_DEST/openclaw.plugin.json"
cp -f "$INSTALL_DIR/package.json"          "$PLUGIN_DEST/package.json"
cp -rf "$INSTALL_DIR/src"                  "$PLUGIN_DEST/src"

echo "  Plugin files copied to $PLUGIN_DEST"

# ── Step 7: Write worktool config into openclaw.json ────
echo "[7] Writing WorkTool config into openclaw.json..."

CONFIG_FILE="$OPENCLAW_HOME/openclaw.json"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "  ERROR: $CONFIG_FILE not found. Run onboard first."
  exit 1
fi

PUBLIC_IP="$(curl -fsS --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")"

python3 - <<PYEOF
import json, os, sys

p = os.path.expanduser('$CONFIG_FILE')
with open(p) as f:
    cfg = json.load(f)

# Remove stale worktool entries before writing fresh ones
cfg.setdefault('channels', {}).pop('worktool', None)
cfg.setdefault('plugins', {}).setdefault('entries', {}).pop('worktool', None)
cfg['plugins'].setdefault('installs', {}).pop('worktool', None)
allow = cfg['plugins'].get('allow', [])
cfg['plugins']['allow'] = [x for x in allow if x != 'worktool']

# Write fresh config
cfg['plugins']['entries']['worktool'] = {'enabled': True, 'config': {}}
cfg['plugins']['installs']['worktool'] = {
    'source': 'path',
    'sourcePath': os.path.expanduser('$PLUGIN_DEST')
}
if 'worktool' not in cfg['plugins']['allow']:
    cfg['plugins']['allow'].append('worktool')

cfg['channels']['worktool'] = {
    'enabled': True,
    'robotId': '$ROBOT_ID',
    'bridgeBaseUrl': '$BRIDGE_BASE_URL',
    'webhookHost': '$WEBHOOK_HOST',
    'webhookPort': int('$WEBHOOK_PORT'),
    'webhookPath': '$WEBHOOK_PATH'
}

# Gateway control UI
gw = cfg.setdefault('gateway', {})
gw.setdefault('port', int('$GATEWAY_PORT'))
ui = gw.setdefault('controlUi', {})
ui['allowInsecureAuth'] = True
ui['dangerouslyDisableDeviceAuth'] = True
origins = ui.get('allowedOrigins', [])
for u in ['http://127.0.0.1:$GATEWAY_PORT', 'http://localhost:$GATEWAY_PORT']:
    if u not in origins:
        origins.append(u)
pub = '$PUBLIC_IP'
if pub:
    pu = 'http://' + pub + ':$GATEWAY_PORT'
    if pu not in origins:
        origins.append(pu)
ui['allowedOrigins'] = origins

with open(p, 'w') as f:
    json.dump(cfg, f, indent=2)

print('  openclaw.json updated.')
if pub:
    print('  Public access: http://' + pub + ':$GATEWAY_PORT')
PYEOF

echo ""

# ── Step 8: Setup systemd service for gateway ───────────
echo "[8] Setting up systemd service ($SERVICE_NAME)..."

OPENCLAW_BIN="$(command -v openclaw)"
GATEWAY_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"

if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
  cat > "$GATEWAY_SERVICE" <<SVCEOF
[Unit]
Description=OpenClaw Gateway
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.npm-global/bin
ExecStart=$OPENCLAW_BIN gateway --bind lan --port $GATEWAY_PORT
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" 2>/dev/null || true
  systemctl restart "$SERVICE_NAME" 2>/dev/null || true
  echo "  Systemd service '$SERVICE_NAME' enabled and started."
else
  echo "  systemd not available, starting gateway in background..."
  pkill -f "openclaw gateway" 2>/dev/null || true
  sleep 1
  nohup openclaw gateway --bind lan --port "$GATEWAY_PORT" \
    >> "$OPENCLAW_HOME/gateway.log" 2>&1 &
  echo "  Gateway started (PID $!), log: $OPENCLAW_HOME/gateway.log"
fi

# ── Step 9: Verify webhook ───────────────────────────────
echo ""
echo "[9] Waiting for webhook (${HEALTH_WAIT}s)..."

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
  echo "  Check logs:"
  if command -v systemctl >/dev/null 2>&1; then
    echo "    journalctl -u $SERVICE_NAME -f"
  else
    echo "    tail -f $OPENCLAW_HOME/gateway.log"
  fi
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
echo "  Upgrade later: re-run this script — OpenClaw will be updated to latest."
echo "  Config saved to $ENV_FILE"
echo ""
