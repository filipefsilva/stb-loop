#!/usr/bin/env bash
#
# setup.sh — Full installation of STB Channel Loop
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# The script:
#   1. Creates system user 'stb-loop'
#   2. Installs OS dependencies (adb, python3)
#   3. Copies the project to /opt/stb-loop
#   4. Installs Python dependencies
#   5. Creates and enables the systemd service
#
set -euo pipefail

APP_USER="stb-loop"
APP_DIR="/opt/stb-loop"
SERVICE_NAME="stb-loop.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
LOOPTIME="${LOOPTIME:-10}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Initial checks
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root:  sudo ./setup.sh"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "${SCRIPT_DIR}/loop.py" ]; then
    err "loop.py not found in ${SCRIPT_DIR}. Run the script from the project folder."
fi

log "=== STB Channel Loop — Installation ==="
log "User      : ${APP_USER}"
log "Target    : ${APP_DIR}"
log "Looptime  : ${LOOPTIME}s"

# ---------------------------------------------------------------------------
# 0. USB OTG overlay for Pi Zero (2) W
# ---------------------------------------------------------------------------

NEEDS_REBOOT=false

ensure_dwc2_overlay() {
    local model
    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)

    # Only needed on Pi Zero / Zero 2 W (BCM2835 / BCM2710A1)
    case "$model" in
        "Raspberry Pi Zero"*"W"*|"Raspberry Pi Zero 2"*)
            ;;
        *)
            log "USB OTG overlay not needed on this model ($model)."
            return
            ;;
    esac

    # Find the right config.txt location
    local config_file
    if [ -f /boot/firmware/config.txt ]; then
        config_file=/boot/firmware/config.txt
    elif [ -f /boot/config.txt ]; then
        config_file=/boot/config.txt
    else
        warn "Cannot find config.txt — USB OTG may not work."
        return
    fi

    # Already configured?
    if grep -qE '^\s*dtoverlay\s*=\s*dwc2' "$config_file" 2>/dev/null; then
        log "dwc2 overlay already present in config.txt."
        return
    fi

    warn "Pi Zero (2) W detected — adding dwc2 USB OTG overlay..."
    warn "A REBOOT will be needed after this installation."

    # Add to the [all] section, or at the end of the file
    if grep -q '^\[all\]' "$config_file"; then
        sed -i '/^\[all\]/a dtoverlay=dwc2,dr_mode=host' "$config_file"
    else
        echo -e "\n[all]\ndtoverlay=dwc2,dr_mode=host" >> "$config_file"
    fi

    log "dwc2 overlay added to $config_file"
    NEEDS_REBOOT=true
}

ensure_dwc2_overlay

# ---------------------------------------------------------------------------
# 1. Create system user
# ---------------------------------------------------------------------------

log "1/5 Creating user '${APP_USER}' ..."

if id "${APP_USER}" &>/dev/null; then
    warn "User '${APP_USER}' already exists."
else
    useradd --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --comment "STB Channel Loop service user" \
        "${APP_USER}"
    log "User '${APP_USER}' created."
fi

# ---------------------------------------------------------------------------
# 2. Install OS dependencies
# ---------------------------------------------------------------------------

log "2/5 Installing system dependencies ..."

apt update -qq
apt install -y -qq adb python3 python3-pip

log "ADB $(adb version 2>/dev/null | head -1 || echo 'installed')"
log "Python $(python3 --version)"

# ---------------------------------------------------------------------------
# 3. Copy project files
# ---------------------------------------------------------------------------

log "3/5 Copying project to ${APP_DIR} ..."

mkdir -p "${APP_DIR}"
cp "${SCRIPT_DIR}/loop.py" "${APP_DIR}/"
cp "${SCRIPT_DIR}/requirements.txt" "${APP_DIR}/" 2>/dev/null || true

# Copy config.json if it already exists (created by the wizard)
if [ -f "${SCRIPT_DIR}/config.json" ]; then
    cp "${SCRIPT_DIR}/config.json" "${APP_DIR}/"
    log "config.json copied."
else
    warn "config.json not found. Run 'python3 ${APP_DIR}/loop.py --stb' after installation."
fi

# ---------------------------------------------------------------------------
# 4. Install Python dependencies
# ---------------------------------------------------------------------------

log "4/5 Installing Python dependencies ..."

if [ -f "${APP_DIR}/requirements.txt" ]; then
    # Only run pip if there are actual packages (skip comments/empty lines)
    deps=$(grep -v '^\s*#' "${APP_DIR}/requirements.txt" | grep -v '^\s*$' | wc -l)
    if [ "$deps" -gt 0 ]; then
        pip3 install -q -r "${APP_DIR}/requirements.txt" --break-system-packages || true
    fi
fi
log "Python dependencies OK."

# ---------------------------------------------------------------------------
# 5. Create and enable systemd service
# ---------------------------------------------------------------------------

log "5/5 Configuring systemd service ..."

cat > "${SERVICE_FILE}" << SYSTEMD
[Unit]
Description=STB Channel Loop — NOC Display
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 ${APP_DIR}/loop.py --looptime ${LOOPTIME}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${APP_DIR}
ReadOnlyPaths=/usr/bin/adb

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"

# Check status
sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "Service '${SERVICE_NAME}' is active and running."
else
    warn "Service may have failed to start. Check: journalctl -u ${SERVICE_NAME} -f"
fi

# ---------------------------------------------------------------------------
# Final permissions
# ---------------------------------------------------------------------------

chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
chmod 755 "${APP_DIR}"
chmod 640 "${APP_DIR}/config.json" 2>/dev/null || true
chmod 755 "${APP_DIR}/loop.py"

# Grant the stb-loop user permission to use ADB
usermod -a -G plugdev "${APP_USER}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
log "============================================"
log " Installation complete!"
log "============================================"
echo ""
echo "  Useful commands:"
echo "  ─────────────────────────────────────────"
echo "  Configure STB:    python3 ${APP_DIR}/loop.py --stb"
echo "  Service status:   sudo systemctl status ${SERVICE_NAME}"
echo "  Live logs:        journalctl -u ${SERVICE_NAME} -f"
echo "  Restart:          sudo systemctl restart ${SERVICE_NAME}"
echo "  Stop:             sudo systemctl stop ${SERVICE_NAME}"
echo "  Uninstall:        sudo systemctl disable --now ${SERVICE_NAME}"
echo ""
echo "  Current looptime: ${LOOPTIME}s  (change with: LOOPTIME=30 sudo ./setup.sh)"
echo ""

if [ "$NEEDS_REBOOT" = true ]; then
    warn "============================================"
    warn " USB OTG overlay was added to config.txt."
    warn " REBOOT REQUIRED before ADB over USB will work:"
    warn ""
    warn "   sudo reboot"
    warn ""
    warn " After reboot, run:  python3 ${APP_DIR}/loop.py --stb"
    warn "============================================"
fi

echo ""
