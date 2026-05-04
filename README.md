# STB Channel Loop — NOC Display

Python script for Raspberry Pi (Zero W, Zero 2 W, or any model) that
continuously cycles through channels on an Android TV Box (STB) via ADB,
for permanent display on a NOC screen.

Supports two connection modes:
- **TCP** — over the network (Wi-Fi/Ethernet)
- **USB** — direct USB cable connection

---

## Requirements

- Raspberry Pi running Raspberry Pi OS (Bookworm or Bullseye)
- Python 3 (included by default in Raspberry Pi OS)
- ADB installed on the Pi
- Android TV Box with ADB debugging enabled
- **USB mode:** data-capable USB cable (not a charge-only cable)

---

## Quick Install (recommended)

```bash
# Clone the repository
git clone https://github.com/filipefsilva/stb-loop.git
cd stb-loop

# Install everything (creates service user, installs deps, sets up systemd)
sudo ./setup.sh

# On Pi Zero / Zero 2 W: a REBOOT is required after setup.sh
# (the script auto-configures the dwc2 USB OTG overlay)
sudo reboot

# Configure the STB
sudo python3 /opt/stb-loop/loop.py --stb
```

The `stb-loop.service` is active and starts automatically on every boot.

Use `LOOPTIME=30 sudo ./setup.sh` to change the zap interval (default: 10s).

---

## Enable ADB Debugging on the STB (Android TV Box)

Exact steps vary by firmware, but the general procedure is:

1. Go to **Settings → About device**
2. Tap **Build number** 7 times to enable developer options
3. Go to **Settings → Developer options**
4. Enable **USB Debugging**
5. **TCP mode:** Also enable **Network ADB Debugging** (*ADB over network*)
6. **TCP mode:** Note the STB's IP address under **Settings → Network**

> **Note:** Some devices (e.g. Xiaomi, NVIDIA Shield) have these options in slightly different menus. Search for "ADB" in Settings.
>
> **USB mode:** Only standard USB Debugging is required. Connect the USB cable between the Pi and the STB.

---

## Configure the STB (Interactive Wizard)

```bash
sudo python3 /opt/stb-loop/loop.py --stb
```

The wizard first asks for the connection mode (TCP or USB), then prompts for the required details.

### TCP Mode

```json
{
  "adb_mode": "tcp",
  "stb_ip": "192.168.1.100",
  "stb_port": 5555
}
```

### USB Mode

```json
{
  "adb_mode": "usb",
  "app_package": "tv.perception.android.tvcabostp",
  "app_activity": "tv.perception.android.waterloo.WaterlooActivity",
  "reconnect_on_fail": true,
  "reconnect_max_retries": 3,
  "reconnect_retry_delay": 1
}
```

The `config.json` file is created automatically under `/opt/stb-loop/`.

#### USB Mode — First Connection & Authorization

When you first connect the Android TV via USB, the TV will show a
**"Allow USB debugging?"** popup. You may see this popup **twice**:

1. **First time:** when the USB cable is physically connected
2. **Second time:** when `adb server` starts on the Pi and generates its RSA key

Check **"Always allow from this computer"** and tap **Allow** on both prompts.
After that, the authorization is permanent.

#### Auto-Launch App (optional)

If `app_package` is configured, the script will:
- Check if the app is already running (via `pidof`)
- Launch it automatically via `am start` if it's not

This is useful when the STB's IPTV app exits or the device restarts.

#### Reconnect Settings

| Field | Default | Description |
|---|---|---|
| `reconnect_on_fail` | `true` | Automatically attempt to reconnect if ADB drops |
| `reconnect_max_retries` | `3` | Max reconnection attempts before giving up |
| `reconnect_retry_delay` | `1` | Seconds between reconnection attempts |

**USB mode:** the reconnect sequence does `adb kill-server` + `adb start-server`
to force device re-enumeration.

**TCP mode:** uses `adb disconnect` + `adb connect`.

---

## Run Manually (Without the Service)

```bash
# Default interval (10 seconds between zaps)
python3 /opt/stb-loop/loop.py

# Custom interval (e.g. 30 seconds)
python3 /opt/stb-loop/loop.py --looptime 30
```

The script reconnects automatically if the ADB connection drops.  
Press **CTRL+C** to stop.

---

## Manage the systemd Service

`setup.sh` already configures and enables the service. Management commands:

```bash
# Service status
sudo systemctl status stb-loop.service

# Live logs
journalctl -u stb-loop.service -f

# Restart
sudo systemctl restart stb-loop.service

# Stop / disable
sudo systemctl stop stb-loop.service
sudo systemctl disable stb-loop.service
```

---

## Update to the Latest Version

Whenever code changes are pushed to the repo, update on the Raspberry Pi with:

```bash
cd ~/stb-loop
git pull
sudo ./update.sh
```

`update.sh` copies the new files to `/opt/stb-loop`, installs any new Python dependencies, and restarts the service.

---

## Service File (Created Automatically by setup.sh)

```ini
[Unit]
Description=STB Channel Loop — NOC Display
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=stb-loop
WorkingDirectory=/opt/stb-loop
ExecStart=/usr/bin/python3 /opt/stb-loop/loop.py --looptime 10
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/stb-loop
ReadOnlyPaths=/usr/bin/adb

[Install]
WantedBy=multi-user.target
```

---

## Project Structure

```
stb-loop/
  loop.py          — main script
  setup.sh         — full installation script
  update.sh        — update script
  requirements.txt — Python dependencies
  config.json      — STB configuration (generated by --stb wizard)
  README.md        — this file
```

---

## Quick Reference

| Action | Command |
|---|---|
| Install everything | `sudo ./setup.sh` |
| Install (30s interval) | `LOOPTIME=30 sudo ./setup.sh` |
| Configure STB | `sudo python3 /opt/stb-loop/loop.py --stb` |
| Run manually (10s) | `python3 /opt/stb-loop/loop.py` |
| Run manually (30s) | `python3 /opt/stb-loop/loop.py --looptime 30` |
| Update app | `git pull && sudo ./update.sh` |
| Service status | `sudo systemctl status stb-loop.service` |
| Live logs | `journalctl -u stb-loop.service -f` |
| Restart service | `sudo systemctl restart stb-loop.service` |

---

## Troubleshooting

**`adb: command not found`**  
→ `setup.sh` installs it automatically. Manually: `sudo apt install -y adb`

**`Connection refused` when connecting to the STB**  
→ Verify that Network ADB Debugging is enabled on the STB and the IP/port in `config.json` are correct.

**STB asks for ADB connection confirmation**  
→ Connect a display to the STB, accept the debugging authorization, and check "Always allow from this computer".

**Script connects but the channel doesn't change**  
→ Make sure the STB is running a live TV app that supports `KEYCODE_CHANNEL_UP`. Some streaming apps ignore this keycode.

**USB mode: device not detected**
→ Check the following:

1. **Cable:** Must be a data-capable USB cable (not charge-only). Test with another cable.
2. **Port:** On Pi Zero (2) W, use the inner micro-USB port (labeled "USB"), not the outer one ("PWR").
3. **USB Debugging:** Must be enabled in Developer Options on the Android TV.
4. **Pi Zero (2) W OTG overlay:** The `dwc2` kernel module must be loaded.
   `setup.sh` auto-configures this, but a **reboot** is required afterward.
   Verify with: `grep dwc2 /boot/firmware/config.txt | tail -1`
5. **Udev rules:** If `adb devices` shows nothing but `lsusb` shows the device,
   create a udev rule:
   ```bash
   echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666"' | sudo tee /etc/udev/rules.d/51-android.rules
   sudo udevadm control --reload-rules
   sudo udevadm trigger
   ```
   (Find your vendor ID with `lsusb` — common ones: `18d1` Google, `22b8` Motorola)

**USB mode: device shows `unauthorized`**
→ Accept the "Allow USB debugging?" popup on the Android TV screen.
   Check "Always allow from this computer" to make it permanent.
   If the popup doesn't appear: unplug/replug the USB cable, or restart ADB:
   ```bash
   adb kill-server
   adb start-server
   adb devices
   ```

**Service won't start**  
→ Check the logs: `journalctl -u stb-loop.service -f`. Make sure `config.json` exists in `/opt/stb-loop/`.

---

## Uninstall

```bash
sudo systemctl disable --now stb-loop.service
sudo rm -rf /opt/stb-loop
sudo userdel stb-loop
```
