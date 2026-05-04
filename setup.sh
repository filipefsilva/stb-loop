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
LOOPTIME="${LOOPTIME:-20}"

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

    # Already configured in [all] section?
    # The dwc2 line inside [cm5] does NOT apply to Pi Zero — it's conditional.
    # Only count lines that are outside conditional sections ([cm4], [cm5], etc.).
    if awk 'BEGIN{ok=1} /^\[cm[0-9]\]/{ok=0} /^\[all\]/{ok=1} /dtoverlay\s*=\s*dwc2/ && ok{found=1; exit} END{exit !found}' "$config_file" 2>/dev/null; then
        log "dwc2 overlay already present in [all] section."
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
    # Each grep may return 1 on no matches; wrap with || true for pipefail safety
    deps=$( (grep -v '^\s*#' "${APP_DIR}/requirements.txt" || true) | (grep -v '^\s*$' || true) | wc -l )
    deps=${deps:-0}
    if [ "$deps" -gt 0 ]; then
        pip3 install -q -r "${APP_DIR}/requirements.txt" --break-system-packages || true
    fi
fi
log "Python dependencies OK."

# ---------------------------------------------------------------------------
# 5. Create and enable systemd service
# ---------------------------------------------------------------------------

log "5/5 Configuring systemd service ..."

# Create shared ADB key for the stb-loop user
ADB_DIR="${APP_DIR}/.android"
mkdir -p "${ADB_DIR}"
if [ ! -f "${ADB_DIR}/adbkey" ]; then
    HOME="${APP_DIR}" adb keygen "${ADB_DIR}/adbkey" 2>/dev/null || true
    log "ADB key generated for user '${APP_USER}'."
fi
chown -R "${APP_USER}:${APP_USER}" "${ADB_DIR}"
chmod 700 "${ADB_DIR}"
chmod 600 "${ADB_DIR}"/adbkey* 2>/dev/null || true

cat > "${SERVICE_FILE}" << SYSTEMD
[Unit]
Description=STB Channel Loop — NOC Display
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=HOME=${APP_DIR}
Environment=ADB_VENDOR_KEYS=${ADB_DIR}
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

if [ "$NEEDS_REBOOT" = true ]; then
    warn "============================================"
    warn " USB OTG overlay was added to config.txt."
    warn " REBOOT REQUIRED before ADB over USB will work:"
    warn ""
    warn "   sudo reboot"
    warn ""
    warn " After reboot, continue with the steps below:"
    warn "============================================"
    echo ""
fi

echo "  Next steps:"
echo "  ─────────────────────────────────────────"
echo "  1. Authorize the service user for USB debugging:"
echo "     sudo -u ${APP_USER} HOME=${APP_DIR} adb devices"
echo "     If the popup doesn't appear on the TV:"
echo "       → TV Settings → Developer Options → 'Revoke USB debugging authorizations'"
echo "       → Then re-run the adb command above"
echo ""
echo "  2. Configure the STB:"
echo "     sudo python3 ${APP_DIR}/loop.py --stb"
echo ""
echo "  Useful commands:"
echo "  ─────────────────────────────────────────"
echo "  Service status:   sudo systemctl status ${SERVICE_NAME}"
echo "  Live logs:        journalctl -u ${SERVICE_NAME} -f"
echo "  Restart:          sudo systemctl restart ${SERVICE_NAME}"
echo "  Stop:             sudo systemctl stop ${SERVICE_NAME}"
echo "  Looptime:         ${LOOPTIME}s  (change: LOOPTIME=30 sudo ./setup.sh)"
echo ""
