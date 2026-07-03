# AkvaLink 🏊

[![Latest release](https://img.shields.io/github/v/release/stenmo/AkvaLink?color=0aa2c0&label=latest&logo=github)](https://github.com/stenmo/AkvaLink/releases/latest)

**Battery-powered Matter pool & aquatic temperature sensor**
Single-SoC design on **u-blox NORA-W40** (ESP32-C6, Wi-Fi 6 + Thread + BLE 5.3)

> Multi-year battery life. Local Matter connectivity. No cloud, ever.

**🌐 Live demo & landing page: [stenmo.github.io/AkvaLink](https://stenmo.github.io/AkvaLink/)**
(available in [English](https://stenmo.github.io/AkvaLink/) · [Svenska](https://stenmo.github.io/AkvaLink/index.sv.html) — connect to a nearby sensor live over Bluetooth, right in your browser)

---

## Why AkvaLink?

Pool, spa, aquarium, wine cellar, or cold-storage temperature monitoring —
environments where the temperature barely changes, but you want to know
**immediately** if it does.

- **🔋 Years on 2× AA** — adaptive sampling + Matter SED + threshold reporting
- **📱 Works with Apple Home, Google Home, Alexa** — standard Matter sensor
- **🌐 No cloud** — local Matter over Thread or Wi-Fi
- **💧 Waterproof probe** — DS18B20 in stainless steel (10 m+ cable possible)
- **🛠 Open source** — built on esp-matter, Apache-2.0 license

## Hardware

| Component | Part | Why |
|-----------|------|-----|
| Module | NORA-W401 / NORA-W406 | Wi-Fi 6 + Thread + BLE in one tiny module |
| MCU | ESP32-C6 (RISC-V @ 160 MHz) | Inside NORA-W40 |
| Sensor | DS18B20 (stainless probe) | ±0.5 °C, 12-bit (0.0625 °C steps), 1-Wire, ~$3 |
| Power | 2× AA alkaline (or 18650 Li) | ~12 years on 2× AA in pool conditions |

**Schematic (direct GPIO, default build):**

```
                        ┌──────────────────────────────────────────┐
                        │       NORA-W40 / EVK-NORA-W40            │
  +3V3 ────────┬─────── │ GPIO15 (J15.4)  ← DS18B20 DQ 1-Wire     │
               │        │                                          │
              4.7 kΩ    │ GPIO9  (BOOT)   ← re-provision button    │
               │        │                   long-press 5 s →       │
DS18B20 ───────┘        │                   erase Wi-Fi, re-prov   │
  DQ ─────────────────► │                                          │
  VDD ────────────────── │ +3V3            ← future: battery ADC   │
  GND ────────────────── │ GND                                     │
                        │                     ┌──────────┐         │
  Battery (+) ──── R1 ──┤ ADCx (future) ◄─────┤ R1 / R2  │        │
  Battery (-) ──── GND  │                     │ divider  │        │
                        └──────────────────────┴──────────┴────────┘
```

R1/R2 voltage divider (not yet populated): e.g. 390 kΩ / 100 kΩ scales 3.3 V full-charge to ≈ 0.68 V, safely within the ESP32-C6 ADC input range.

For long cable runs (> 5 m), a DS2482-800 I2C-to-1-Wire bridge variant is also
supported (`--clickboard` build flag).

## Quick start

```powershell
# One-time setup (installs ESP-IDF + esp-matter in WSL, ~10 GB)
.\launch-akvalink-wsl.cmd setup

# Build & flash (Thread variant — needs a Thread Border Router)
.\launch-akvalink-wsl.cmd build
.\launch-akvalink-wsl.cmd flash COM62

# Or build the Wi-Fi variant (no border router needed)
.\launch-akvalink-wsl.cmd --wifi build

# Or the Wi-Fi AP variant — open "AkvaLink" hotspot + captive web page showing
# the temperature. No hub, no app, works on ANY phone (incl. iPhone).
# NOTE: an always-on SoftAP is NOT battery-friendly — this variant needs
# external (mains/USB) power.
.\launch-akvalink-wsl.cmd --ap build

# Or the Wi-Fi station variant — joins your home Wi-Fi (provisioned once over
# BLE with the free "ESP BLE Provisioning" app), then serves the temperature
# page at http://akvalink-<last4mac>.local (unique per device). Also publishes
# to MQTT for Home Assistant autodiscovery (default broker: homeassistant.local:1883).
.\launch-akvalink-wsl.cmd --station build

# Or just bench-test the DS18B20 probe (no Matter/BLE — logs temp every 30 s)
.\launch-akvalink-wsl.cmd --sensor build
```

Commission with the Apple Home, Google Home, or Alexa app — scan the QR code
printed on the serial console at first boot.

📖 **Full step-by-step:** see [GETTING_STARTED.md](GETTING_STARTED.md)

## Battery life examples

For a heated pool at 28–29 °C with 0.25 °C report threshold:

| Battery | Thread SED | Wi-Fi (TWT) | Wi-Fi (disconnect) |
|---------|-----------|-------------|--------------------|
| CR2477 (1000 mAh) | ~5 years | ~6 months | ~3.3 years |
| 2× AAA (1200 mAh) | ~6 years | ~8 months | ~4 years |
| **2× AA (2800 mAh)** | **~12 years** | **~1.8 years** | **~9 years** |
| 18650 (3400 mAh) | ~15+ years | ~2.2 years | ~11 years |

See [docs/POWER_AND_HARDWARE.md](docs/POWER_AND_HARDWARE.md) for the full
analysis (DTIM strategies, TWT setup, sensor variants, schematic).

## Project docs

- 📖 [GETTING_STARTED.md](GETTING_STARTED.md) — clone → build → flash → commission
- 📶 [docs/CONNECTIVITY.md](docs/CONNECTIVITY.md) — Matter/Thread, Matter/Wi-Fi, BLE-only, Wi-Fi standalone + provisioning
- ⚡ [docs/POWER_AND_HARDWARE.md](docs/POWER_AND_HARDWARE.md) — battery math, schematic
- ❄️ [docs/WINTER_STORAGE_MODE.md](docs/WINTER_STORAGE_MODE.md) — "drop it in the pool and forget it" mode
- 📺 [docs/EINK_DISPLAY_PLAN.md](docs/EINK_DISPLAY_PLAN.md) — e-ink panel shortlist + integration plan
- 🏊 [docs/ENCLOSURE_DESIGN.md](docs/ENCLOSURE_DESIGN.md) — Smart Float industrial design + mechanical details
- 📡 [docs/RF_AND_ANTENNA.md](docs/RF_AND_ANTENNA.md) — NORA-W40 antenna keep-out + over-water RF rules
- ✅ [TODO.md](TODO.md) — prioritised roadmap (power, smart reporting, e-ink, winter mode)
- ⚠️ [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) — what doesn't work yet, honestly

## Roadmap

- [x] Matter Temperature Sensor over Thread (single-SoC, NORA-W40)
- [x] Matter Temperature Sensor over Wi-Fi
- [x] Adaptive sampling + threshold reporting
- [x] Light sleep + DFS + flash power-down
- [x] DS2482 Click board (long cable variant)
- [x] BLE firmware update over the air (custom GATT over `esp_ota`, `--ble` variant)
- [x] Standalone BLE GATT variant — live temperature direct-to-app, no hub (`--ble`)
- [x] Live temperature in the browser over Web Bluetooth — on the [landing page](https://stenmo.github.io/AkvaLink/)
- [x] Wi-Fi AP variant (`--ap`) — open hotspot + captive web page, any phone incl. iPhone (needs external power)
- [x] Wi-Fi station variant (`--station`) — BLE-provisioned, `akvalink.local`, **Home Assistant MQTT autodiscovery**, no hub
- [ ] **Real power measurement (Joulescope/PPK2) + deep sleep** — see [TODO.md](TODO.md)
- [ ] **E-ink display** (big-digit, battery, trend) — see [docs/EINK_DISPLAY_PLAN.md](docs/EINK_DISPLAY_PLAN.md)
- [ ] Wi-Fi 6 TWT integration in code (currently DTIM only)
- [ ] Battery voltage monitoring + low-battery Matter event
- [ ] OTA via Matter
- [ ] Production enclosure design (waterproof, IP67)

## Origin & Credits

AkvaLink is a clean-room productisation of the
`companion/opencpu/nora-w40-thermometer/` NORA-W40 thermometer reference from
u-blox, tracked at [u-blox/u-connectMatter](https://github.com/u-blox/u-connectMatter)
(that public repo now hosts prebuilt reference binaries; the source tree is
internal to u-blox).

Built on:
- [esp-matter](https://github.com/espressif/esp-matter) (release/v1.5)
- [ESP-IDF](https://github.com/espressif/esp-idf) (v5.4.1)
- [connectedhomeip](https://github.com/project-chip/connectedhomeip) (Matter SDK)
- u-blox NORA-W40 module ([product page](https://www.u-blox.com/en/product/nora-w40-series))

## Contributing & security

- 🤝 [CONTRIBUTING.md](CONTRIBUTING.md) — how to build, test, and submit changes (KISS, battery-first, no cloud)
- 🔒 [SECURITY.md](SECURITY.md) — report a vulnerability privately (AkvaLink is a networked Matter device)

## License

[Apache-2.0](LICENSE) — matches esp-matter and connectedhomeip.
