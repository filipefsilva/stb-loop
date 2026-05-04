#!/usr/bin/env python3
"""
STB Channel Loop — NOC Display
Continuous channel zapping via ADB (USB or TCP) on an Android TV Box.
Supports USB (cable) or TCP (network) connection.
"""

import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

CONFIG_FILE = Path(__file__).parent / "config.json"
DEFAULT_LOOP_TIME = 10
DEFAULT_ADB_MODE = "tcp"
ADB_PORT_DEFAULT = 5555
MAX_RETRIES = 20
RETRY_DELAY = 5
RECONNECT_ON_FAIL = True
RECONNECT_MAX_RETRIES = 3
RECONNECT_RETRY_DELAY = 1
APP_PACKAGE_DEFAULT = ""
APP_ACTIVITY_DEFAULT = ""


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
        stream=sys.stdout,
    )


log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def load_config() -> dict:
    if not CONFIG_FILE.exists():
        log.error("Config file not found: %s", CONFIG_FILE)
        log.error("Run first:  python loop.py --stb")
        sys.exit(1)
    with open(CONFIG_FILE) as f:
        cfg = json.load(f)

    # ADB mode (default: tcp)
    mode = cfg.get("adb_mode", DEFAULT_ADB_MODE)
    if mode not in ("tcp", "usb"):
        log.error("Invalid 'adb_mode': '%s'. Use 'tcp' or 'usb'.", mode)
        sys.exit(1)
    cfg["adb_mode"] = mode

    # Required fields depending on mode
    if mode == "tcp":
        for key in ("stb_ip", "stb_port"):
            if key not in cfg:
                log.error("Field '%s' missing in config.json (TCP mode).", key)
                sys.exit(1)

    # Optional: app to launch on startup
    cfg.setdefault("app_package", APP_PACKAGE_DEFAULT)
    cfg.setdefault("app_activity", APP_ACTIVITY_DEFAULT)

    # Optional: reconnect settings
    cfg.setdefault("reconnect_on_fail", RECONNECT_ON_FAIL)
    cfg.setdefault("reconnect_max_retries", RECONNECT_MAX_RETRIES)
    cfg.setdefault("reconnect_retry_delay", RECONNECT_RETRY_DELAY)

    return cfg


def save_config(cfg: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)
    log.info("Configuration saved to %s", CONFIG_FILE)


# ---------------------------------------------------------------------------
# Interactive wizard
# ---------------------------------------------------------------------------

def wizard():
    print("\n=== STB Channel Loop — Setup ===\n")

    # Choose ADB mode
    print("ADB connection mode:")
    print("  1 — TCP (network)")
    print("  2 — USB (cable)")
    while True:
        choice = input(f"Choice [default: {DEFAULT_ADB_MODE}]: ").strip().lower()
        if not choice:
            choice = DEFAULT_ADB_MODE
            break
        if choice in ("1", "tcp"):
            choice = "tcp"
            break
        if choice in ("2", "usb"):
            choice = "usb"
            break
        print("Invalid option. Choose 1 (TCP) or 2 (USB).")
    mode = choice
    cfg = {"adb_mode": mode}

    if mode == "tcp":
        while True:
            ip = input("\nSTB IP address (e.g. 192.168.1.100): ").strip()
            if not ip:
                print("IP cannot be empty.")
                continue
            ip_pattern = r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"
            if not re.match(ip_pattern, ip):
                print("Invalid IP format. Use: 192.168.1.100")
                continue
            if not all(0 <= int(octet) <= 255 for octet in ip.split(".")):
                print("IP octets out of 0-255 range.")
                continue
            break
        port_str = input(f"ADB port [default: {ADB_PORT_DEFAULT}]: ").strip()
        port = int(port_str) if port_str else ADB_PORT_DEFAULT
        cfg["stb_ip"] = ip
        cfg["stb_port"] = port
        target_desc = f"{ip}:{port}"
    else:
        target_desc = "USB (cable)"
        print("\nUSB mode: the STB will be auto-detected.")
        print("Make sure the USB cable is connected and USB Debugging is enabled.\n")

        # Diagnose USB connection
        result = adb("devices")
        lines = [l.strip() for l in result.stdout.strip().split("\n") if l.strip()]
        # First line is "List of devices attached"
        devices = [l for l in lines if l and not l.startswith("List")]
        authorized = [l for l in devices if l.endswith("\tdevice")]
        unauthorized = [l for l in devices if l.endswith("\tunauthorized")]

        if authorized:
            print(f"✅ Found {len(authorized)} device(s):")
            for d in authorized:
                print(f"   {d}")
        elif unauthorized:
            print(f"⚠️  Device found but NOT authorized:")
            for d in unauthorized:
                print(f"   {d}")
            print("   👉 Accept the USB Debugging prompt on the Android TV screen!")
        else:
            print("❌ No ADB device found over USB.")
            print()
            print("   Troubleshooting:")
            print("   1. Is a data-capable USB cable connected?")
            print("   2. Is USB Debugging enabled on the Android TV?")
            print("   3. On Pi Zero (2) W: does config.txt have 'dtoverlay=dwc2'?")
            print("      Run:  grep dwc2 /boot/firmware/config.txt")
            print("      If missing, run setup.sh (sudo ./setup.sh) to auto-configure it.")
            print()
            print("   ⚠️  If dwc2 was just added, a REBOOT is required.")
            print()
            ok = input("   Continue anyway? [y/N]: ").strip().lower()
            if ok != "y":
                print("Setup cancelled. Fix the USB connection and try again.")
                sys.exit(1)

    save_config(cfg)
    print(f"\nConfiguration saved: mode={mode} | {target_desc}")

    # Optional: configure app to launch
    print("\nAuto-launch app on startup (optional):")
    pkg = input("  Package name (e.g. com.example.app) [skip]: ").strip()
    if pkg:
        cfg["app_package"] = pkg
        act = input("  Activity name (e.g. .MainActivity) [skip]: ").strip()
        if act:
            cfg["app_activity"] = act
        save_config(cfg)
        print("App launch configured.")

    # Optional: reconnect settings
    print("\nReconnect settings:")
    print("  1 — Enabled (default)")
    print("  2 — Disabled")
    rc = input(f"  Choice [1]: ").strip()
    if rc == "2":
        cfg["reconnect_on_fail"] = False
        save_config(cfg)

    print("\nYou can now run:  python loop.py\n")


# ---------------------------------------------------------------------------
# ADB helpers
# ---------------------------------------------------------------------------

def adb(*args) -> subprocess.CompletedProcess:
    """Run an ADB command and return the result."""
    cmd = ["adb"] + list(args)
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        log.warning("ADB command timed out: %s", " ".join(cmd))
        # Return a result with non-zero exit code for the caller to handle
        return subprocess.CompletedProcess(cmd, -1, stdout="", stderr="timeout")


def adb_connect(cfg: dict) -> bool:
    """Connect to the STB. For USB mode, just checks if the device is present."""
    if cfg["adb_mode"] == "usb":
        return adb_is_connected(cfg)

    target = f"{cfg['stb_ip']}:{cfg['stb_port']}"
    log.info("Connecting to STB %s ...", target)
    result = adb("connect", target)
    output = (result.stdout + result.stderr).strip()
    log.info("adb connect: %s", output)
    return "connected" in output.lower()


def adb_is_connected(cfg: dict) -> bool:
    """Check if the STB is connected via ADB."""
    result = adb("devices")
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # ADB device lines are format: "<serial>\tdevice"
        parts = line.split()
        if len(parts) != 2 or parts[1] != "device":
            continue
        serial = parts[0]
        if cfg["adb_mode"] == "usb":
            # USB devices show up without ':' in the serial
            if ":" not in serial:
                return True
        else:
            target = f"{cfg['stb_ip']}:{cfg['stb_port']}"
            if serial == target:
                return True
    return False


def adb_send_keycode(cfg: dict, keycode: str) -> bool:
    """Send a keyevent to the STB."""
    if cfg["adb_mode"] == "usb":
        result = adb("-d", "shell", "input", "keyevent", keycode)
    else:
        target = f"{cfg['stb_ip']}:{cfg['stb_port']}"
        result = adb("-s", target, "shell", "input", "keyevent", keycode)
    return result.returncode == 0


def adb_open_app(cfg: dict) -> bool:
    """Bring the configured app to the foreground on the STB.
    Always issues 'am start' — it's fast and idempotent:
    if the app is already in foreground, nothing changes."""
    pkg = cfg.get("app_package", "")
    act = cfg.get("app_activity", "")
    if not pkg:
        return True  # no app configured, not a failure

    component = f"{pkg}/{act}" if act else pkg
    if cfg["adb_mode"] == "usb":
        result = adb("-d", "shell", "am", "start", "-n", component)
    else:
        target = f"{cfg['stb_ip']}:{cfg['stb_port']}"
        result = adb("-s", target, "shell", "am", "start", "-n", component)

    output = (result.stdout + result.stderr).strip()
    # Success: "Starting: Intent..." or "brought to the front"
    if result.returncode == 0:
        log.debug("App foreground: %s", output.split(chr(10))[0] if output else "OK")
        return True
    else:
        # Only log warning if it actually failed (not just "brought to front")
        if "Error" in output and "brought to the front" not in output:
            log.warning("Failed to bring app to foreground: %s", output)
            return False
        return True


def adb_reconnect(cfg: dict) -> bool:
    """Attempt to reconnect to the STB. For USB, reset the ADB server.
    For TCP, issue 'adb connect'."""
    if cfg["adb_mode"] == "usb":
        # For USB: kill/start server to force device re-enumeration
        adb("kill-server")
        time.sleep(1)
        adb("start-server")
        time.sleep(2)
    else:
        target = f"{cfg['stb_ip']}:{cfg['stb_port']}"
        adb("disconnect", target)
        time.sleep(1)
    return adb_connect(cfg)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def channel_loop(cfg: dict, loop_time: int):
    mode = cfg["adb_mode"]
    target_desc = "USB" if mode == "usb" else f"{cfg['stb_ip']}:{cfg['stb_port']}"
    keycode = "KEYCODE_CHANNEL_UP"

    # Reconnect settings from config
    reconnect_on_fail = cfg.get("reconnect_on_fail", RECONNECT_ON_FAIL)
    reconnect_max_retries = cfg.get("reconnect_max_retries", RECONNECT_MAX_RETRIES)
    reconnect_delay = cfg.get("reconnect_retry_delay", RECONNECT_RETRY_DELAY)

    log.info("Starting channel loop — STB: %s | Mode: %s | Interval: %ss",
             target_desc, mode, loop_time)
    log.info("Press CTRL+C to stop.")

    # Initial connection — wait forever, retry with backoff
    attempts = 0
    delay = RETRY_DELAY
    while not adb_connect(cfg):
        attempts += 1
        log.warning("Waiting for STB (attempt %d). Retrying in %ds...", attempts, delay)
        time.sleep(delay)
        delay = min(delay * 2, 60)  # exponential backoff, cap at 60s

    # Launch app if configured
    time.sleep(2)  # give the device a moment after connection
    adb_open_app(cfg)

    zap_count = 0

    try:
        while True:
            if not adb_is_connected(cfg):
                log.warning("Connection lost.")
                if not reconnect_on_fail:
                    log.error("Reconnect disabled in config. Exiting.")
                    sys.exit(1)

                connected = False
                attempts = 0
                delay = reconnect_delay
                while not connected:
                    attempts += 1
                    if reconnect_max_retries > 0 and attempts > reconnect_max_retries:
                        log.error("Reconnection failed after %d attempts. Exiting.",
                                  reconnect_max_retries)
                        sys.exit(1)
                    log.warning("Reconnecting (attempt %d/%d)...",
                                attempts, reconnect_max_retries)
                    connected = adb_reconnect(cfg)
                    if not connected:
                        time.sleep(delay)
                        delay = min(delay * 2, 30)  # backoff, cap at 30s

                log.info("Reconnected successfully.")
                # Re-launch app in case the STB was restarted
                time.sleep(1)
                adb_open_app(cfg)

            # Ensure app is running before zapping
            adb_open_app(cfg)

            ok = adb_send_keycode(cfg, keycode)
            zap_count += 1
            if ok:
                log.info("Zap #%d → %s sent", zap_count, keycode)
            else:
                log.warning("Zap #%d → failed to send %s", zap_count, keycode)

            time.sleep(loop_time)

    except KeyboardInterrupt:
        log.info("Interrupted by user (CTRL+C). Total zaps: %d", zap_count)
        sys.exit(0)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    setup_logging()

    # Check that ADB is installed
    if shutil.which("adb") is None:
        log.error("ADB not found. Install with: sudo apt install -y adb")
        sys.exit(1)

    parser = argparse.ArgumentParser(
        description="STB Channel Loop — continuous channel cycling via ADB for NOC display"
    )
    parser.add_argument(
        "--looptime",
        type=int,
        default=DEFAULT_LOOP_TIME,
        metavar="N",
        help=f"Seconds between zaps (default: {DEFAULT_LOOP_TIME})",
    )
    parser.add_argument(
        "--stb",
        action="store_true",
        help="Launch the interactive wizard to configure the STB connection",
    )

    args = parser.parse_args()

    if args.stb:
        wizard()
        return

    cfg = load_config()
    channel_loop(cfg, args.looptime)


if __name__ == "__main__":
    main()
