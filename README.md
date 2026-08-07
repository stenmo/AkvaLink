# AkvaLink 💧

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
| Power | 2× AA alkaline (or 18650 Li) | ~5–7 years realistic on 2× AA (Thread SED, pool conditions)* |

**Schematic (direct GPIO, default build):**

```
                         ┌──────────────────────────────────────────┐
                         │       NORA-W40 / EVK-NORA-W40            │
  +3V3 ────────┬──────── │ GPIO15 (J15.4)  ← DS18B20 DQ 1-Wire      │
               │         │                                          │
              4.7 kΩ     │ GPIO9  (BOOT)   ← re-provision button    │
               │         │                   long-press 5 s →       │
DS18B20 ───────┘         │                   erase Wi-Fi, re-prov   │
  DQ ──────────────────► │                                          │
  VDD ────────────────── │ +3V3            ← future: battery ADC    │
  GND ────────────────── │ GND                                      │
                         │                     ┌──────────┐         │
  Battery (+) ──── R1 ───┤ ADCx (future) ◄─────┤ R1 / R2  │         │
  Battery (-) ──── GND   │                     │ divider  │         │
                         └─────────────────────┴──────────┴─────────┘
```

R1/R2 voltage divider (not yet populated): e.g. 390 kΩ / 100 kΩ scales 3.3 V full-charge to ≈ 0.68 V, safely within the ESP32-C6 ADC input range.

For long cable runs (> 5 m), a DS2482-800 I2C-to-1-Wire bridge variant is also
supported (`--clickboard` build flag).

## Quick start

```powershell
# One-time setup (installs ESP-IDF + esp-matter in WSL, ~10 GB)
.\akvalink.cmd setup

# Build & flash (Thread variant — needs a Thread Border Router)
.\akvalink.cmd build
.\akvalink.cmd flash COM62

# Or build the Wi-Fi variant (no border router needed)
.\akvalink.cmd --wifi build

# Or the Wi-Fi AP variant — open "AkvaLink" hotspot + captive web page showing
# the temperature. No hub, no app, works on ANY phone (incl. iPhone).
# NOTE: an always-on SoftAP is NOT battery-friendly — this variant needs
# external (mains/USB) power.
.\akvalink.cmd --ap build

# Or the Wi-Fi station variant — joins your home Wi-Fi (provisioned once over
# BLE with the free "ESP BLE Provisioning" app), then serves the temperature
# page at http://akvalink-<last4mac>.local (found via mDNS, unique per device).
# Also publishes to MQTT for Home Assistant autodiscovery (default broker:
# homeassistant.local:1883), plus high/low temperature alerts on
# akvalink/<mac>/alert once you set a threshold (menuconfig → AkvaLink).
.\akvalink.cmd --station build

# Or just bench-test the DS18B20 probe (no Matter/BLE — logs temp every 30 s)
.\akvalink.cmd --sensor build

# Or the ESP-NOW variant — deep-sleep broadcast, no hub, no provisioning,
# maximum battery life (receiver needs its own ESP32 sketch).
.\akvalink.cmd --espnow build

# Or ESPHome — native Home Assistant API, adopted + OTA-updated straight from
# the ESPHome dashboard. Builds with ESPHome directly, not akvalink.cmd:
esphome compile esphome/akvalink.yaml
```

Commission with the Apple Home, Google Home, or Alexa app — scan the QR code
printed on the serial console at first boot.

📖 **Full step-by-step:** see [GETTING_STARTED.md](docs/GETTING_STARTED.md)

### Companion app (optional)

A native **Flutter** app (Windows/Linux/macOS/Android/iOS) shows live
temperature over Bluetooth or Wi-Fi (finds a `--station` device on the LAN via
mDNS) and one-click OTA-updates the device — same GATT/HTTP contract as the
web page, no browser needed:

```powershell
.\akvalink.cmd --app --run
```

📖 See [app_flutter/README.md](app_flutter/README.md).

## Battery life examples

For a heated pool at 28–29 °C with 0.25 °C report threshold. **Realistic
expectation: 5–7 years** on alkaline AA/AAA — shelf life and self-discharge
cap them well below the draw-limited numbers below. CR2477 (lithium primary)
has the best shelf life and lands closest to its modeled figure; 18650
(Li-ion) calendar-ages a few percent capacity per year regardless of load, so
treat it like the alkaline rows, not as decades:

| Battery | Thread SED | Wi-Fi (TWT) | Wi-Fi (disconnect) |
|---------|-----------|-------------|--------------------|
| CR2477 (1000 mAh) | ~5 years | ~6 months | ~3.3 years |
| 2× AAA (1200 mAh)* | ~6 years | ~8 months | ~4 years |
| **2× AA (2800 mAh)*** | **~12 years** | **~1.8 years** | **~9 years** |
| 18650 (3400 mAh)* | ~15+ years | ~2.2 years | ~11 years |

<sup>*</sup> Draw-limited power-model estimate — self-discharge/calendar aging
caps real-world life well below this for alkaline and Li-ion cells. Real
measurement (PPK2/Joulescope) is on the roadmap.

See [docs/POWER_AND_HARDWARE.md](docs/POWER_AND_HARDWARE.md) for the full
analysis (DTIM strategies, TWT setup, sensor variants, schematic).

## Project docs

- 📖 [GETTING_STARTED.md](docs/GETTING_STARTED.md) — clone → build → flash → commission
- 📶 [docs/CONNECTIVITY.md](docs/CONNECTIVITY.md) — Matter/Thread, Matter/Wi-Fi, BLE-only, Wi-Fi standalone + provisioning
- ⚡ [docs/POWER_AND_HARDWARE.md](docs/POWER_AND_HARDWARE.md) — battery math, schematic
- ❄️ [docs/WINTER_STORAGE_MODE.md](docs/WINTER_STORAGE_MODE.md) — "drop it in the pool and forget it" mode
- 📺 [docs/EINK_DISPLAY_PLAN.md](docs/EINK_DISPLAY_PLAN.md) — e-ink panel shortlist + integration plan
- 💧 [docs/ENCLOSURE_DESIGN.md](docs/ENCLOSURE_DESIGN.md) — Smart Float industrial design + mechanical details
- 📡 [docs/RF_AND_ANTENNA.md](docs/RF_AND_ANTENNA.md) — NORA-W40 antenna keep-out + over-water RF rules
- ✅ [TODO.md](TODO.md) — prioritised roadmap (power, smart reporting, e-ink, winter mode)
- ⚠️ [KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md) — what doesn't work yet, honestly

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
- [x] ESP-NOW variant (`--espnow`) — deep-sleep broadcast, no hub, no provisioning
- [x] ESPHome variant — native Home Assistant API, dashboard-adopted + dashboard OTA
- [x] Native Flutter companion app (Windows/Linux/macOS/Android/iOS) — live temperature + one-click OTA
- [x] Temperature alerts — high/low thresholds set from the browser or the app, stored on the device; the `--station` build publishes crossings to Home Assistant over MQTT
- [x] 24 h / 7 d history — sparkline on the device's own page and in the app (Wi-Fi path; RAM-only, resets on reboot)
- [x] Matter keepalive report so a dead-flat sensor isn't marked offline
- [ ] **Real power measurement (Joulescope/PPK2) + deep sleep** — see [TODO.md](TODO.md)
- [ ] **E-ink display** (big-digit, battery, trend) — see [docs/EINK_DISPLAY_PLAN.md](docs/EINK_DISPLAY_PLAN.md)
- [ ] Wi-Fi 6 TWT integration in code (currently DTIM only)
- [ ] Battery voltage monitoring — firmware side is in (`CONFIG_AKVALINK_BATTERY_ADC`, off by default), but no board has the sense divider fitted, so the level reads as *unknown*
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
- [ESP-IDF](https://github.com/espressif/esp-idf) (v5.5.5)
- [connectedhomeip](https://github.com/project-chip/connectedhomeip) (Matter SDK)
- u-blox NORA-W40 module ([product page](https://www.u-blox.com/en/product/nora-w40-series))

## Contributing & security

- 🤝 [CONTRIBUTING.md](.github/CONTRIBUTING.md) — how to build, test, and submit changes (KISS, battery-first, no cloud)
- 🔒 [SECURITY.md](.github/SECURITY.md) — report a vulnerability privately (AkvaLink is a networked Matter device)

## License

[Apache-2.0](LICENSE) — matches esp-matter and connectedhomeip.
