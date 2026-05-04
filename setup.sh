#!/usr/bin/env bash
#
# setup.sh — Full installation of STB Channel Loop
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# The script:
#   0. Configures dwc2 USB OTG overlay on Pi Zero (2) W
#   1. Creates system user 'stb-loop'
#   2. Installs OS dependencies (adb, python3, pip)
#   3. Interactive config: looptime, app package/activity
#   4. Copies project to /opt/stb-loop
#   5. Installs Python dependencies
#   6. Creates shared ADB key + systemd service
#   7. Guides ADB authorization
#
set -euo pipefail

APP_USER="stb-loop"
APP_DIR="/opt/stb-loop"
SERVICE_NAME="stb-loop.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
ADB_DIR="${APP_DIR}/.android"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
ask()  { echo -e "${CYAN}[?]${NC} $*"; }

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

# ---------------------------------------------------------------------------
# 0. USB OTG overlay for Pi Zero (2) W
# ---------------------------------------------------------------------------

NEEDS_REBOOT=false

ensure_dwc2_overlay() {
    local model
    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)

    case "$model" in
        "Raspberry Pi Zero"*"W"*|"Raspberry Pi Zero 2"*)
            ;;
        *)
            log "USB OTG overlay not needed on this model ($model)."
            return
            ;;
    esac

    local config_file
    if [ -f /boot/firmware/config.txt ]; then
        config_file=/boot/firmware/config.txt
    elif [ -f /boot/config.txt ]; then
        config_file=/boot/config.txt
    else
        warn "Cannot find config.txt — USB OTG may not work."
        return
    fi

    if awk 'BEGIN{ok=1} /^\[cm[0-9]\]/{ok=0} /^\[all\]/{ok=1} /dtoverlay\s*=\s*dwc2/ && ok{found=1; exit} END{exit !found}' "$config_file" 2>/dev/null; then
        log "dwc2 overlay already present in [all] section."
        return
    fi

    warn "Pi Zero (2) W detected — adding dwc2 USB OTG overlay..."
    warn "A REBOOT will be needed after this installation."

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

log "1/7 Creating system user '${APP_USER}' ..."

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

log "2/7 Installing system dependencies ..."

apt update -qq
apt install -y -qq adb python3 python3-pip

log "ADB $(adb version 2>/dev/null | head -1 || echo 'installed')"
log "Python $(python3 --version)"

# ---------------------------------------------------------------------------
# 3. Interactive configuration
# ---------------------------------------------------------------------------

echo ""
echo -e "${GREEN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│          STB Channel Loop — Config           │${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────┘${NC}"
echo ""

# Looptime
echo "Zap interval (seconds between channel changes):"
read -r -p "  [default: 20]: " LOOPTIME
LOOPTIME="${LOOPTIME:-20}"
# Validate numeric
if ! [[ "$LOOPTIME" =~ ^[0-9]+$ ]] || [ "$LOOPTIME" -lt 1 ]; then
    warn "Invalid looptime. Using default: 20"
    LOOPTIME=20
fi
log "Looptime set to: ${LOOPTIME}s"
echo ""

# App package (required — without it the loop has nothing to launch)
APP_PACKAGE=""
APP_ACTIVITY=""
echo "App to launch before each channel change (required):"
echo "  This ensures the IPTV app is in foreground for zapping."
while [ -z "$APP_PACKAGE" ]; do
    read -r -p "  Package name: " APP_PACKAGE
    APP_PACKAGE="${APP_PACKAGE:-}"
    if [ -z "$APP_PACKAGE" ]; then
        echo ""
        warn "No package name provided."
        warn "Without an app to launch, the loop cannot work properly."
        read -r -p "  Abort installation? [Y/n]: " ABORT
        ABORT="${ABORT:-y}"
        if [[ "$ABORT" =~ ^[Yy] ]]; then
            echo ""
            log "Installation aborted by user."
            exit 0
        fi
        echo ""
    fi
done

# Activity name
while [ -z "$APP_ACTIVITY" ]; do
    read -r -p "  Activity name: " APP_ACTIVITY
    APP_ACTIVITY="${APP_ACTIVITY:-}"
    if [ -z "$APP_ACTIVITY" ]; then
        echo ""
        warn "No activity provided — app auto-launch may not work."
        read -r -p "  Continue without activity? [y/N]: " NOACT
        NOACT="${NOACT:-n}"
        if [[ "$NOACT" =~ ^[Yy] ]]; then
            warn "Proceeding without activity. App launch may fail."
            break
        fi
        echo ""
    fi
done

log "App configured: ${APP_PACKAGE}${APP_ACTIVITY:+ / $APP_ACTIVITY}"
echo ""

# Write config.json early so it's available to the service
CONFIG_FILE="${APP_DIR}/config.json"
mkdir -p "${APP_DIR}"

python3 - << PYEOF
import json
cfg = {
    "app_package": "${APP_PACKAGE}",
    "app_activity": "${APP_ACTIVITY}",
    "reconnect_on_fail": True,
    "reconnect_max_retries": 0,
    "reconnect_retry_delay": 1
}
with open("${CONFIG_FILE}", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
log "Configuration saved."

# ---------------------------------------------------------------------------
# 4. Copy project files
# ---------------------------------------------------------------------------

log "4/7 Copying project files to ${APP_DIR} ..."

cp "${SCRIPT_DIR}/loop.py" "${APP_DIR}/"
cp "${SCRIPT_DIR}/requirements.txt" "${APP_DIR}/" 2>/dev/null || true
log "Files copied."

# ---------------------------------------------------------------------------
# 5. Install Python dependencies
# ---------------------------------------------------------------------------

log "5/7 Installing Python dependencies ..."

if [ -f "${APP_DIR}/requirements.txt" ]; then
    deps=$( (grep -v '^\s*#' "${APP_DIR}/requirements.txt" || true) | (grep -v '^\s*$' || true) | wc -l )
    deps=${deps:-0}
    if [ "$deps" -gt 0 ]; then
        pip3 install -q -r "${APP_DIR}/requirements.txt" --break-system-packages || true
    fi
fi
log "Python dependencies OK."

# ---------------------------------------------------------------------------
# 6. Shared ADB key + systemd service
# ---------------------------------------------------------------------------

log "6/7 Setting up ADB key and systemd service ..."

# Create shared ADB key (used by both root and stb-loop)
mkdir -p "${ADB_DIR}"
if [ ! -f "${ADB_DIR}/adbkey" ]; then
    HOME="${APP_DIR}" adb keygen "${ADB_DIR}/adbkey" 2>/dev/null || true
    log "ADB key generated in ${ADB_DIR}"
fi
chown -R "${APP_USER}:${APP_USER}" "${ADB_DIR}"
chmod 700 "${ADB_DIR}"
chmod 600 "${ADB_DIR}"/adbkey* 2>/dev/null || true

# Create systemd service
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

# Permissions
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
chmod 755 "${APP_DIR}"
chmod 755 "${APP_DIR}/loop.py"
chmod 640 "${APP_DIR}/config.json" 2>/dev/null || true

usermod -a -G plugdev "${APP_USER}" 2>/dev/null || true

log "Service '${SERVICE_NAME}' configured."

# ---------------------------------------------------------------------------
# 7. ADB authorization
# ---------------------------------------------------------------------------

echo ""
echo -e "${GREEN}┌─────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│          ADB Authorization                   │${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────┘${NC}"
echo ""

# Use the shared key for authorization checks
export ADB_VENDOR_KEYS="${ADB_DIR}"

# Check if a USB device is connected
DEVICE_STATE=$(adb devices 2>/dev/null | grep -v "List of devices" | grep -v "^$" | awk '{print $2}' | head -1)
DEVICE_STATE="${DEVICE_STATE:-none}"

case "$DEVICE_STATE" in
    device)
        log "ADB device already authorized — no popup needed."
        ;;
    unauthorized)
        warn "ADB device found but NOT authorized."
        echo ""
        echo "   👉 Check the Android TV screen for an 'Allow USB debugging?' popup."
        echo "   If the popup doesn't appear:"
        echo "     1. TV Settings → Developer Options → 'Revoke USB debugging authorizations'"
        echo "     2. Unplug and replug the USB cable"
        echo ""
        read -r -p "   Press Enter after accepting the popup on the TV... "
        # Re-check
        DEVICE_STATE=$(adb devices 2>/dev/null | grep -v "List of devices" | grep -v "^$" | awk '{print $2}' | head -1)
        if [ "$DEVICE_STATE" = "device" ]; then
            log "ADB device authorized successfully."
        else
            warn "Device still unauthorized. You can authorize later with:"
            warn "  sudo -u ${APP_USER} HOME=${APP_DIR} ADB_VENDOR_KEYS=${ADB_DIR} adb devices"
            warn "The service will wait until the device is authorized."
        fi
        ;;
    *)
        echo "No ADB device detected over USB."
        echo ""
        echo "   Make sure:"
        echo "   1. The USB cable is connected (data cable, not charge-only)"
        echo "   2. USB Debugging is enabled on the Android TV"
        echo ""
        if [ "$NEEDS_REBOOT" = true ]; then
            echo "   ⚠️  A reboot is required for the USB port to work."
        else
            echo "   Is the Android TV powered on and the cable connected?"
        fi
        echo ""
        echo "   The service will start and wait for the device."
        echo "   You can authorize later with:"
        echo "     sudo -u ${APP_USER} HOME=${APP_DIR} ADB_VENDOR_KEYS=${ADB_DIR} adb devices"
        ;;
esac

# Start the service
systemctl start "${SERVICE_NAME}" 2>/dev/null || true
sleep 2
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "Service is active and running."
else
    warn "Service may have failed to start. Check: journalctl -u ${SERVICE_NAME} -f"
fi

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
    warn " REBOOT REQUIRED"
    warn " The dwc2 USB OTG overlay was added."
    warn " Run: sudo reboot"
    warn "============================================"
    echo ""
fi

echo "  The service is running:  sudo systemctl status ${SERVICE_NAME}"
echo "  Live logs:               journalctl -u ${SERVICE_NAME} -f"
echo "  Looptime:                ${LOOPTIME}s"
echo "  Package:                 ${APP_PACKAGE}${APP_ACTIVITY:+ / $APP_ACTIVITY}"
echo ""
echo "  To reconfigure later:    cd ${SCRIPT_DIR} && sudo ./setup.sh"
echo ""

if [ "$DEVICE_STATE" != "device" ]; then
    echo "  ⚠️  ADB not yet authorized. The service will wait."
    echo "  To authorize now:"
    echo "     sudo -u ${APP_USER} HOME=${APP_DIR} ADB_VENDOR_KEYS=${ADB_DIR} adb devices"
    echo ""
fi
