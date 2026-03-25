#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${MODE:-docker}" # docker|native

case "$MODE" in
  docker)
    exec bash "$ROOT_DIR/scripts/install-local-docker.sh"
    ;;
  native)
    exec bash "$ROOT_DIR/scripts/install-local-native.sh"
    ;;
  *)
    echo "Invalid MODE=${MODE}. Use MODE=docker or MODE=native."
    exit 1
    ;;
esac
