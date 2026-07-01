# AquaLink — TODO

> Living roadmap. **Current scope is deliberately small** (KISS).
> Everything else lives in *Future ideas* below — that's the parking lot,
> not the work list.

---

## Now — pick ONE and finish it

Per `.github/copilot-instructions.md` (KISS): exactly one thing in flight
at a time. Until something here is done, nothing from *Future ideas*
gets started.

- [ ] **Run the EVK end-to-end.** Build → flash → DS18B20 reads → commission
      in Apple Home / Google Home → see the temperature in the app.
      Photo of it working = the moment the project becomes real.
- [ ] **Set up an off-machine git backup.** Private remote (private GitHub,
      Codeberg, Gitea, or just a `git push` to an external drive).
      10-minute job, removes the "single disk failure" risk.

## Next — first measurement

After the EVK works, **one** small step. No new features yet.

- [ ] **Measure the actual average current** in the default Thread SED
      build. PPK2, Joulescope, Otii, or a 10 Ω shunt + scope on the
      EVK 3V3 rail. One number. Compare to the model in
      [docs/POWER_AND_HARDWARE.md](docs/POWER_AND_HARDWARE.md).
      Whatever the number is, that decides the next move.

## Done / shipped

- Initial Matter Temperature Sensor on Thread + Wi-Fi.
- DS18B20 + DS2482-800 sensor paths, both auto-detect.
- Adaptive sampling (fast 3 s / slow 60 s).
- Threshold-gated reporting (default 0.25 °C).
- Light sleep + DFS + flash power-down.
- AquaLink boot banner with PoolMicke nod.
- Local-only git repo, no remote (private project).
- Design docs for power, winter mode, e-ink, enclosure, RF, connectivity.
- Repo cleaned of upstream `u-connectMatter` naming; binary is `aqualink.bin`;
  launcher/build/flash scripts drive-agnostic (WSL `wslpath`, not hardcoded C:).
- Toolchain verified: ESP-IDF v5.4.1 + esp-matter release/v1.5 — the latest
  combo esp-matter v1.5 supports for ESP32-C6 (v5.5.x is C5/C61 only).
- DS18B20 at full 12-bit (0.0625 °C); power managed via adaptive modes +
  report threshold, not resolution (measure vs Nordic PPK2 before tuning).

---

# Future ideas — parking lot

Everything below is **design captured, not work scheduled**. Each bullet
points at the doc that owns the full thinking. Pull items up into *Now*
one at a time, only after the current thing is done and the measurement
above has happened.

## Battery / power
> See [docs/POWER_AND_HARDWARE.md](docs/POWER_AND_HARDWARE.md)
> and [docs/WINTER_STORAGE_MODE.md](docs/WINTER_STORAGE_MODE.md).

- **Resolution vs power:** DS18B20 runs full 12-bit (0.0625 °C, ~750 ms
  conversion). Power is controlled by the adaptive modes (fast/slow periods)
  and the report threshold — *not* by dropping resolution. Measure per-read
  and average current on the **Nordic PPK2** before tuning; only revisit
  12 → 11 → 10-bit if conversion awake-time proves significant.
- Wi-Fi disconnect-mode (wake → associate → push → tear down → sleep).
- Tune Thread SED poll period (120 s → 300 s → 600 s).
- Deep sleep cycles (5–10 min between full samples).
- Power DS18B20 from a switched GPIO + move 1-Wire pull-up to the
  switched rail.
- Audit hidden leaks (LDO Iq, stray pull-ups, floating GPIOs,
  e-ink driver standby). Use `rtc_gpio_isolate()` before deep sleep.
- **Target: < 50 µA average** in normal mode, **< 15 µA** in storage.

## Winter Storage Mode
> See [docs/WINTER_STORAGE_MODE.md](docs/WINTER_STORAGE_MODE.md).

- Explicit entry: long-press BOOT (≥ 5 s) or Matter "holiday" command.
- Tear down Thread / Wi-Fi / BLE; cut sensor + e-ink power; deep sleep.
- Reed-switch (magnet) wake — killer feature for sealed enclosure.
- Fast-rejoin path on wake (skip commissioning splash, first reading
  on e-ink within 2 s).
- Spec **lithium AA / AAA** in user docs (alkaline leaks in cold).
- *Auto-detect storage* — v2 only, too risky for v1.

## Smart reporting
- Keepalive interval (default 4 h, Kconfig) so controllers don't mark
  the device offline.
- Hysteresis on the threshold to stop edge-flicker reporting.
- Boot-time burst suppression (one report in the first 30 s).

## E-ink display
> See [docs/EINK_DISPLAY_PLAN.md](docs/EINK_DISPLAY_PLAN.md).

- Pick panel (recommendation: Waveshare 2.9" or 4.2" SPI).
- Wire on EVK MikroBUS 2; native ESP-IDF SPI driver in
  `main/eink_display.{cpp,h}`.
- Layout: big digit + battery + trend + relative timestamp.
- Refresh policy = same Δ logic as Matter reporting.
- Daily full refresh to clear ghosting.
- P-MOSFET on panel VCC (kills driver-IC standby leak).

## Connectivity / Provisioning (the four modes)
> See [docs/CONNECTIVITY.md](docs/CONNECTIVITY.md).

- Standalone BLE GATT (`--ble-only` build).
- Standalone Wi-Fi (`--wifi-standalone` build, mDNS + HTTP/JSON).
- **Espressif Unified Provisioning — chosen provisioner** (BLE default,
  SoftAP fallback for the laptop-only case — no phone, no app, just a
  browser). In-tree ESP-IDF component, free published app, zero new deps.
- Nordic Wi-Fi Provisioner GATT service on ESP-IDF — *optional, only if the
  "provisions from both ecosystems" demo story is wanted; otherwise skip.*
- WPS-PBC fallback (caveats: no WPA3-only; off on some enterprise APs).
- Optional Improv-Wi-Fi.
- Universal build with runtime mode select.
- Long-press (15 s) factory reset → wipe NVS → provisioning.

## Apps & integrations
> Beyond Matter. AquaLink stays a Matter device first (works today in Apple /
> Google / Alexa / Home Assistant via the standard Temperature Sensor cluster);
> everything here is an *additional*, optional path layered on top — no cloud.
> See [docs/CONNECTIVITY.md](docs/CONNECTIVITY.md) for the connectivity design.

- On-device **config web server** (SoftAP or LAN): browser-based setup and
  live readout, no app install. Pairs with the Wi-Fi standalone build.
- **GATT configuration server** (BLE): set thresholds, sample rates, name,
  and Wi-Fi/Thread creds from a phone with no router present.
- **Universal Flutter companion app** (iOS + Android + desktop): one codebase
  talking BLE GATT and/or local HTTP/JSON — provisioning, live temp, history,
  battery, alerts. Local-only, no account.
- **Home Assistant integration** — works today over Matter; also evaluate a
  native path (local HTTP/JSON REST or MQTT-over-LAN) for users who want
  richer history/automation without a Matter controller.
- Keep every path **local and private** — reuse the same threshold/report
  logic; no new cloud dependency.

## Productisation
> See [docs/ENCLOSURE_DESIGN.md](docs/ENCLOSURE_DESIGN.md)
> and [docs/RF_AND_ANTENNA.md](docs/RF_AND_ANTENNA.md).

- Smart Float enclosure (90 mm body, weighted tip, 60/40 buoyancy,
  tether eyelet, double O-ring hatch, UV-stable ASA).
- Foam-core mockup → PETG print → ASA production part.
- PCB outline matches enclosure; antenna keep-out verified via u-blox
  docs MCP; NORA-W401 (external antenna) for v1.
- Bench A/B RSSI test (antenna in air vs. 20 mm above a tray of pool
  water) before committing tooling.
- 30-day chlorine soak + UV exposure test.
- OTA via Matter (`esp_matter_ota` is linked, not wired).
- Factory provisioning script (NVS data, unique QR code).
- Matter DAC/PAI certification — *research only*, no CSA fees for a demo.

## Nice-to-haves
- Multi-probe support (DS2482-800 already gives 8 channels).
- Cold-storage / freezer alarm endpoint (Boolean State cluster).
- Web-based commissioning helper page (renders QR + PIN — for demo videos).
- Swedish localisation of the boot banner. *Tack Micke.* 🇸🇪
