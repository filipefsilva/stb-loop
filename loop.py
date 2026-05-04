#!/usr/bin/env python3
"""
IPTV Channel Loop
Cycles through channels on an Android TV device via ADB over USB.
Use with any IPTV app that responds to KEYCODE_CHANNEL_UP / KEYCODE_CHANNEL_DOWN.
"""

import argparse
import json
import logging
import shutil
import subprocess
import sys
import time
from pathlib import Path

CONFIG_FILE = Path(__file__).parent / "config.json"
DEFAULT_LOOP_TIME = 10
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
        log.error("Run first:  sudo ./setup.sh")
        sys.exit(1)
    with open(CONFIG_FILE) as f:
        cfg = json.load(f)

    # Optional: app to launch on startup
    cfg.setdefault("app_package", APP_PACKAGE_DEFAULT)
    cfg.setdefault("app_activity", APP_ACTIVITY_DEFAULT)

    # Optional: reconnect settings
    cfg.setdefault("reconnect_on_fail", RECONNECT_ON_FAIL)
    cfg.setdefault("reconnect_max_retries", RECONNECT_MAX_RETRIES)
    cfg.setdefault("reconnect_retry_delay", RECONNECT_RETRY_DELAY)

    return cfg


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
        return subprocess.CompletedProcess(cmd, -1, stdout="", stderr="timeout")


def adb_is_connected() -> bool:
    """Check if a USB device is authorized and connected."""
    result = adb("devices")
    for line in result.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) == 2 and parts[1] == "device" and ":" not in parts[0]:
            return True
    return False


def adb_send_keycode(keycode: str) -> bool:
    """Send a keyevent to the USB device."""
    result = adb("-d", "shell", "input", "keyevent", keycode)
    return result.returncode == 0


def adb_open_app(cfg: dict) -> bool:
    """Bring the configured app to the foreground.
    Always issues 'am start' — fast and idempotent."""
    pkg = cfg.get("app_package", "")
    act = cfg.get("app_activity", "")
    if not pkg:
        return True

    component = f"{pkg}/{act}" if act else pkg
    result = adb("-d", "shell", "am", "start", "-n", component)
    output = (result.stdout + result.stderr).strip()

    if result.returncode == 0:
        log.debug("App foreground: %s", output.split("\n")[0] if output else "OK")
        return True
    else:
        if "Error" in output and "brought to the front" not in output:
            log.warning("Failed to bring app to foreground: %s", output)
            return False
        return True


def adb_reconnect() -> bool:
    """Reset the ADB server to force device re-enumeration over USB."""
    adb("kill-server")
    time.sleep(1)
    adb("start-server")
    time.sleep(2)
    return adb_is_connected()


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def channel_loop(cfg: dict, loop_time: int):
    keycode = "KEYCODE_CHANNEL_UP"

    reconnect_on_fail = cfg.get("reconnect_on_fail", RECONNECT_ON_FAIL)
    reconnect_max_retries = cfg.get("reconnect_max_retries", RECONNECT_MAX_RETRIES)
    reconnect_delay = cfg.get("reconnect_retry_delay", RECONNECT_RETRY_DELAY)

    log.info("Starting channel loop — USB | Interval: %ss", loop_time)
    log.info("Press CTRL+C to stop.")

    # Initial connection — wait forever, retry with backoff
    attempts = 0
    delay = RETRY_DELAY
    while not adb_is_connected():
        attempts += 1
        log.warning("Waiting for STB (attempt %d). Retrying in %ds...", attempts, delay)
        time.sleep(delay)
        delay = min(delay * 2, 60)

    # Launch app if configured
    time.sleep(2)
    adb_open_app(cfg)

    zap_count = 0

    try:
        while True:
            if not adb_is_connected():
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
                    connected = adb_reconnect()
                    if not connected:
                        time.sleep(delay)
                        delay = min(delay * 2, 30)

                log.info("Reconnected successfully.")
                time.sleep(1)
                adb_open_app(cfg)

            # Ensure app is running before zapping
            adb_open_app(cfg)

            ok = adb_send_keycode(keycode)
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

    if shutil.which("adb") is None:
        log.error("ADB not found. Install with: sudo apt install -y adb")
        sys.exit(1)

    parser = argparse.ArgumentParser(
        description="IPTV Channel Loop — cycles through channels via ADB over USB"
    )
    parser.add_argument(
        "--looptime",
        type=int,
        default=DEFAULT_LOOP_TIME,
        metavar="N",
        help=f"Seconds between channel changes (default: {DEFAULT_LOOP_TIME})",
    )

    args = parser.parse_args()

    cfg = load_config()
    channel_loop(cfg, args.looptime)


if __name__ == "__main__":
    main()
