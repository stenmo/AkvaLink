# Getting Started with AkvaLink

## Prerequisites

- **Windows 10/11** with **WSL2** + Ubuntu 24.04 installed
  (`wsl --install -d Ubuntu-24.04` from an elevated PowerShell)
- **VS Code** (recommended) with the Remote-WSL extension
- **EVK-NORA-W40** board (NORA-W401 or NORA-W406) + USB-C cable
- **DS18B20** sensor + 4.7 kΩ resistor (or a MikroE I2C 1-Wire Click board)
- ~15 GB free disk space (ESP-IDF + esp-matter toolchains)

## 1. Get the code

**If the repo is on GitHub:**
```powershell
git clone https://github.com/u-blox/AkvaLink.git
cd AkvaLink
```

**If you only have the local copy** (current state — May 2026):
```powershell
cd C:\Users\cmag\u-blox\AkvaLink
```

Open in VS Code:
```powershell
code .
```

## 2. One-time WSL setup (~10 GB, takes ~30 min on first run)

This installs ESP-IDF v5.4.1 and esp-matter release/v1.5 inside WSL:

```powershell
.\akvalink.cmd setup
```

The launcher will:
1. Verify WSL Ubuntu-24.04 is running
2. Clone ESP-IDF into `~/esp/esp-idf` (WSL home)
3. Clone esp-matter into `~/esp/esp-matter` and check out v1.5
4. Install all required Python packages and the ESP32-C6 toolchain
5. Verify the install with `idf.py --version`

You only run `setup` once per machine.

## 3. Build the firmware

**Default — Matter over Thread, direct GPIO sensor:**
```powershell
.\ akvalink.cmd build
```

**Wi-Fi variant (no Thread Border Router needed):**
```powershell
.\akvalink.cmd --wifi build
```

**DS2482 Click board variant (I2C bridge for long cable runs):**
```powershell
.\akvalink.cmd --clickboard build
```

A cold build takes 5–10 min; subsequent incremental builds are < 1 min.

## 4. Find your COM port

Plug in the EVK-NORA-W40 via USB-C, then:

```powershell
# List all COM ports — NORA-W40 EVK shows up via FTDI bridge
Get-PnpDevice -Class Ports -PresentOnly | Where-Object { $_.FriendlyName -like '*USB Serial*' -or $_.FriendlyName -like '*FTDI*' }
```

Note the COM port number (e.g., `COM62`).

## 5. Flash and monitor

```powershell
.\akvalink.cmd flash COM62
.\akvalink.cmd monitor COM62
```

In the monitor output you should see:

```
I (1234) AkvaLink: 🏊 AkvaLink v0.1.0 starting...
I (1416) ds2482: 1-Wire ROM: 28-0417C4A2D3FF-2A (DS18B20)
I (1420) ds2482: Power supply: external VDD
I (1425) ds2482: Resolution: 12-bit
I (2000) chip[DL]: Setup PIN code: 20202021
I (2010) chip[DL]: QR code: MT:Y.K9042C00KA0648G00
```

Press **Ctrl+]** to exit the monitor.

## 6. Commission with a Matter controller

Open Apple Home, Google Home, or Alexa → Add Accessory → scan the QR code from
the serial console. The device will join your Matter fabric and appear as a
**Temperature Sensor**.

For Thread builds you also need a **Thread Border Router** on the network
(Apple HomePod mini / Apple TV 4K, Google Nest Hub 2nd gen, Amazon Echo Hub,
or a self-hosted OTBR like the ones in the upstream `u-connectMatter/borderrouters/`).

## 7. (Optional) Push to GitHub

The repo currently has no remote. To back it up to GitHub:

```powershell
# 1. Create an empty repo at https://github.com/new (e.g., u-blox/AkvaLink)
#    Do NOT initialize with README/license — we already have those.

# 2. Add remote and push
cd C:\Users\cmag\u-blox\AkvaLink
git remote add origin https://github.com/u-blox/AkvaLink.git
git push -u origin main
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `wsl` errors with `0x80070569` | Run `net stop vmcompute && net start vmcompute` from elevated **cmd.exe** |
| COM port not visible in WSL | WSL2 sees Windows COM ports as `/dev/ttyS<N>` (e.g. COM62 → `/dev/ttyS62`). Run `sudo chmod 666 /dev/ttyS62` inside WSL |
| `idf.py: command not found` after setup | Open a new WSL shell so `~/.bashrc` re-sources the IDF environment |
| `No DS18B20 found` at boot | Check 4.7 kΩ pull-up between DQ and +3V3, and that all 3 wires reach the sensor |
| Flash fails with `A fatal error occurred` | Hold the **BOOT** button on EVK while flashing starts |
| `1-Wire ROM CRC mismatch` | Cable is too long for direct GPIO — switch to `--clickboard` (DS2482) variant |

## Next steps

- Read [README.md](../README.md) for the product pitch and battery-life numbers
- Read [docs/POWER_AND_HARDWARE.md](POWER_AND_HARDWARE.md) for the deep
  power analysis (TWT, DTIM, disconnect strategies, schematic)
- Read [.github/copilot-instructions.md](../.github/copilot-instructions.md) to
  understand the project's design rules before making changes
