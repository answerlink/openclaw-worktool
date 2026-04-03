#!/usr/bin/env bash
set -euo pipefail

# ── One-liner for Linux cloud servers ───────────────────
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/answerlink/openclaw-worktool/main/scripts/setup-remote.sh -o /tmp/oc-setup.sh; bash /tmp/oc-setup.sh
#
# With pre-set variables (non-interactive):
#   ROBOT_ID=xxx SKIP_ONBOARD=1 bash /tmp/oc-setup.sh

REPO="answerlink/openclaw-worktool"
INSTALL_DIR="${INSTALL_DIR:-$HOME/openclaw-worktool}"
MIN_MEM_MB="${MIN_MEM_MB:-3500}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

echo ""
echo "=============================================="
echo "  OpenClaw + WorkTool — Remote Setup"
echo "=============================================="
echo ""

# ── 1) Check Docker ────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Installing via official script..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker 2>/dev/null || true
  systemctl start docker 2>/dev/null || true
  echo "Docker installed."
  echo ""
fi

# ── 2) Configure Docker registry mirrors (China) ─────
DAEMON_JSON="/etc/docker/daemon.json"
if [ -f "$DAEMON_JSON" ] && grep -q "registry-mirrors" "$DAEMON_JSON" 2>/dev/null; then
  echo "Docker mirror: already configured."
else
  echo "Configuring Docker registry mirrors..."
  mkdir -p /etc/docker
  if [ -f "$DAEMON_JSON" ]; then
    # Merge into existing config
    node -e "\
      const fs=require('fs');\
      const p='$DAEMON_JSON';\
      let c={}; try{c=JSON.parse(fs.readFileSync(p,'utf8'))}catch{};\
      c['registry-mirrors']=c['registry-mirrors']||[\
        'https://mirror.ccs.tencentyun.com',\
        'https://docker.mirrors.ustc.edu.cn',\
        'https://docker.1panel.live'\
      ];\
      fs.writeFileSync(p,JSON.stringify(c,null,2));" 2>/dev/null \
    || cat > "$DAEMON_JSON" <<'MIRRORS'
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.mirrors.ustc.edu.cn",
    "https://docker.1panel.live"
  ]
}
MIRRORS
  else
    cat > "$DAEMON_JSON" <<'MIRRORS'
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://docker.mirrors.ustc.edu.cn",
    "https://docker.1panel.live"
  ]
}
MIRRORS
  fi
  systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
  echo "Docker mirror configured and daemon restarted."
fi
echo ""

# ── 3) Check memory & swap ────────────────────────────
TOTAL_MEM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
TOTAL_SWAP_MB="$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

if [ "$TOTAL_MEM_MB" -gt 0 ] && [ "$TOTAL_MEM_MB" -lt "$MIN_MEM_MB" ]; then
  echo "System memory: ${TOTAL_MEM_MB}MB (recommended >= ${MIN_MEM_MB}MB)"

  if [ "$TOTAL_SWAP_MB" -lt 1024 ]; then
    echo "Swap: ${TOTAL_SWAP_MB}MB — adding ${SWAP_SIZE} swap..."
    if [ ! -f /swapfile ]; then
      fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      echo "Swap enabled."
    else
      swapon /swapfile 2>/dev/null || true
      echo "Swap file already exists."
    fi
  else
    echo "Swap: ${TOTAL_SWAP_MB}MB — OK."
  fi

  echo ""
  echo "WARNING: Servers with < 4GB RAM may experience OOM during OpenClaw startup."
  echo "         The script will continue, but onboard/startup might crash."
  echo "         If that happens, add more swap or use a larger server."
  echo ""
fi

# ── 4) Download plugin source ─────────────────────────
if [ -f "$INSTALL_DIR/openclaw.plugin.json" ]; then
  echo "Plugin source found at $INSTALL_DIR, updating..."
  if [ -d "$INSTALL_DIR/.git" ]; then
    cd "$INSTALL_DIR"
    git pull --ff-only 2>/dev/null || echo "  git pull failed, using existing files."
  fi
else
  CLONE_OK=0

  if command -v git >/dev/null 2>&1; then
    echo "Cloning plugin repository..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 "https://github.com/${REPO}.git" "$INSTALL_DIR" && CLONE_OK=1 || {
      echo "  git clone failed, trying tarball download..."
    }
  fi

  if [ "$CLONE_OK" = "0" ]; then
    echo "Downloading plugin source (tarball)..."
    TMP_TAR="$(mktemp)"
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    # Try GitHub directly, then ghproxy mirror for China servers
    curl -fsSL --connect-timeout 15 "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" -o "$TMP_TAR" 2>/dev/null \
      || curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/${REPO}/archive/refs/heads/main.tar.gz" -o "$TMP_TAR" 2>/dev/null \
      || { echo "Download failed. Check network and retry."; exit 1; }

    tar xzf "$TMP_TAR" --strip-components=1 -C "$INSTALL_DIR"
    rm -f "$TMP_TAR"
  fi
fi

cd "$INSTALL_DIR"

if [ ! -f "openclaw.plugin.json" ]; then
  echo "Failed to download plugin source. Check network and retry."
  exit 1
fi

echo "Plugin source ready at $INSTALL_DIR"
echo ""

# ── 5) Delegate to setup-docker.sh ───────────────────
exec bash scripts/setup-docker.sh
