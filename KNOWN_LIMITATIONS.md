# AkvaLink — Known Limitations

> What doesn't work yet, what isn't measured yet, and where the rough edges
> are. Read before opening an issue or evaluating for production.

---

## Power

- **Battery-life numbers in the README are modeled, not measured.**
  They are based on datasheet currents + duty cycle math. A real Joulescope
  / Otii / PPK2 capture is on [TODO.md](TODO.md) (P0). Treat current numbers
  as upper bounds.
- **No deep sleep yet.** Only light sleep + DFS are enabled. Average
  current is therefore higher than the steady-state target.
- **DS18B20 is permanently powered** from the EVK 3V3 rail. It should be
  powered from a GPIO so it can be cut between samples.
- **Wi-Fi build does not disconnect after commissioning.** It stays
  associated and uses TWT or DTIM only. The "report-and-disconnect"
  mode that gives the multi-year Wi-Fi number isn't implemented.

## Matter

- **No keepalive report.** If temperature is genuinely flat for hours,
  controllers (especially Apple Home) may mark the device offline.
  Mitigation today: lower the threshold or wait for the keepalive feature.
- **No OTA.** `esp_matter_ota` is linked but not wired into a working
  update path. Manual reflash is the only update mechanism.
- **No factory data partition.** Commissioning uses esp-matter's
  default test PAA/PAI/DAC. Fine for the demo, not for shipping product.
- **No Matter certification.** This is a demo, not a certified device.
  Don't sell it.

## Hardware

- **Wired only on EVK-NORA-W40.** No custom PCB exists. The "battery
  enclosure" referenced in docs is a planned 3D-printable design, not a
  shipping product.
- **Direct GPIO 1-Wire works to ~5 m of cable.** Beyond that you need
  the `--clickboard` build (DS2482-800). This is a 1-Wire physics limit,
  not a firmware bug.
- **No display yet.** See [docs/EINK_DISPLAY_PLAN.md](docs/EINK_DISPLAY_PLAN.md).
- **Antenna variant matters.** NORA-W401 (external antenna) is required
  inside an enclosure with metal or wet surroundings. NORA-W406 (PCB
  antenna) is fine on a workbench, marginal in a real install.

## Tooling / dev workflow

- **WSL2 only on Windows.** Native Windows build is not supported (esp-matter
  upstream limitation, not ours).
- **`launch-akvalink-wsl.cmd flash` requires the EVK on a native Windows COM
  port.** USB pass-through into WSL via `usbipd-win` is not used; we flash
  from Windows-side `esptool` against the WSL-built artifacts.
- **Build artifacts live in `/mnt/c/...`** which is slower than WSL's native
  ext4. Acceptable cost for the simpler workflow; expect ~2× slower
  incremental builds vs. a pure-WSL project layout.
- **Repo is local-only on purpose** (no GitHub/GitLab remote). This is a
  private side project. If you fork it, set up your own remote.

## Software

- **No tests.** Zero unit tests, zero hardware-in-loop tests. The sensor
  driver and Matter glue are exercised only by running the firmware.
- **No structured logging.** All logs are `ESP_LOGI/W/E` text. No JSON
  output, no metrics export. Fine for a demo, painful for a fleet.
- **No BLE direct-to-app path** (planned, see TODO).
- **No Thread commissioning UX assist.** If commissioning fails you get
  raw esp-matter logs and have to dig.

## Environmental / mechanical (not yet validated)

- **Probe cable run > 30 m is untested**, even with DS2482.
- **Long-term submersion of the DS18B20 stainless probe is untested**
  beyond manufacturer claims. Pool chlorine + 24/7/365 should be fine
  (lots of aquarium thermometers do this), but we have no field data.
- **Operating temperature range** of the EVK enclosure side is dictated
  by the 2× AA alkaline cells (~0 °C to +50 °C). Cold storage / freezer
  use would need lithium primaries (e.g. Energizer Ultimate Lithium).
- **No Winter Storage Mode yet.** Today the device runs its normal
  reporting cycle 24/7/365 — not viable for "put it away in October,
  use it again in May". See
  [docs/WINTER_STORAGE_MODE.md](docs/WINTER_STORAGE_MODE.md) for the
  design, and TODO.md for the implementation plan.
- **Alkaline cells will leak in cold storage.** Use lithium AA / AAA
  (Energizer L91 / L92) for any device that may sit unused over winter.
  We do not detect cell chemistry; if a user puts alkalines in and
  forgets the device for 6 months, the device will likely be destroyed
  by leakage.
