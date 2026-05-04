# IPTV Channel Loop

A lightweight Python script that continuously cycles through channels on an
Android TV device via ADB over USB. Works with any IPTV app where
`KEYCODE_CHANNEL_UP` / `KEYCODE_CHANNEL_DOWN` changes the channel.

---

## Supported Hardware

### Raspberry Pi

| Model | Supported | Notes |
|---|---|---|
| Pi Zero 2 W | ✅ | Requires `dwc2` USB OTG overlay (setup.sh handles this) |
| Pi 3 (A+/B/B+) | ✅ | |
| Pi 4 / Pi 5 | ✅ | |
| Pi Zero (original) | ❌ | ARMv6 — `adb` crashes on this architecture |

### Other Linux Machines

Any Linux system with:

- **Architecture:** x86_64 or aarch64 (ARMv8)
- **RAM:** 256 MB minimum
- **Disk:** 50 MB free
- **USB:** at least one USB host port
- **OS:** any distribution with systemd (Debian, Ubuntu, Fedora, Arch, etc.)

The script is extremely lightweight — it only runs `adb shell input keyevent`
once per interval. CPU and memory usage are negligible.

---

## Requirements

- A supported Linux machine (see above)
- Android TV device with USB debugging enabled
- Data-capable USB cable (not charge-only)

---

## Install

```bash
git clone https://github.com/filipefsilva/stb-loop.git
cd stb-loop
sudo ./setup.sh
```

The installer asks for:

| Setting | Default | Notes |
|---|---|---|
| Loop interval | 20 seconds | Seconds between channel changes |
| App package | *(required)* | Android package to launch (e.g. `com.example.iptv`) |
| App activity | *(optional)* | Activity class; skip at your own risk |

It then installs dependencies, creates a systemd service, and guides you
through ADB authorization on the TV.

On Pi Zero 2 W the installer adds the `dwc2` USB OTG overlay and will tell
you to reboot.

---

## After Install

The service starts automatically on every boot. Nothing to do.

```bash
journalctl -u stb-loop.service -f        # live logs
sudo systemctl status stb-loop.service    # service status
sudo systemctl restart stb-loop.service   # restart
```

**To reconfigure:** `sudo ./setup.sh`
**To update code only:** `cd ~/stb-loop && git pull && sudo ./setup.sh --update`

---

## Enable USB Debugging on the Android TV

1. Settings → About → tap **Build number** 7 times
2. Settings → Developer options → enable **USB debugging**
3. Connect the USB cable to the Linux machine

---

## USB Debugging Authorization

The first time you connect, the TV shows an "Allow USB debugging?" popup.
Check **Always allow** and tap **Allow**.

If the popup doesn't appear:
1. TV Settings → Developer options → **Revoke USB debugging authorizations**
2. Unplug and replug the USB cable
3. Run: `sudo -u stb-loop HOME=/opt/stb-loop ADB_VENDOR_KEYS=/opt/stb-loop/.android adb devices`

---

## Troubleshooting

**Device not detected:**
- Cable must be data-capable (not charge-only)
- Pi Zero 2 W: use the inner USB port ("USB"), not "PWR"
- USB debugging must be enabled on the TV
- Pi Zero 2 W: `dwc2` overlay required — run `sudo ./setup.sh`

**Device shows `unauthorized`:**
→ Revoke authorizations on TV, replug cable, run the `adb devices` command above.

**Service won't start:**
→ `journalctl -u stb-loop.service -f`

**App doesn't launch:**
→ Verify the activity name in `/opt/stb-loop/config.json`, then `sudo systemctl restart stb-loop.service`.

---

## Uninstall

```bash
sudo systemctl disable --now stb-loop.service
sudo rm -rf /opt/stb-loop
sudo userdel stb-loop
```
