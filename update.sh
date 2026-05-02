#!/usr/bin/env bash
#
# update.sh — Update the STB Channel Loop installation
#
# Usage:
#   cd ~/stb-loop   (or wherever you cloned the repo)
#   git pull         (optional — update.sh also does a pull)
#   sudo ./update.sh
#
set -euo pipefail

APP_DIR="/opt/stb-loop"
SERVICE_NAME="stb-loop.service"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[UPDATE]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root:  sudo ./update.sh"
fi

if [ ! -d "${APP_DIR}" ]; then
    err "${APP_DIR} not found. Run 'sudo ./setup.sh' first."
fi

log "=== STB Channel Loop — Update ==="

# 1. Git pull
log "1/4 Pulling latest code via git ..."
if git pull 2>/dev/null; then
    log "Code updated."
else
    warn "git pull failed — continuing with local files."
fi

# 2. Copy files
log "2/4 Copying files to ${APP_DIR} ..."
cp loop.py "${APP_DIR}/"
cp requirements.txt "${APP_DIR}/" 2>/dev/null || true
log "Files copied."

# 3. Install Python dependencies
log "3/4 Installing Python dependencies ..."
if [ -f "${APP_DIR}/requirements.txt" ]; then
    pip3 install -q -r "${APP_DIR}/requirements.txt" || true
fi
log "Dependencies OK."

# 4. Restart service
log "4/4 Restarting service ..."
systemctl restart "${SERVICE_NAME}"
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "Service restarted successfully."
else
    warn "Service may have failed to start. Check: journalctl -u ${SERVICE_NAME} -f"
fi

echo ""
systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null || true
echo ""
log "Update complete."
