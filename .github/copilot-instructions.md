# AkvaLink — AI Coding Instructions

## Project Overview

**AkvaLink** is a battery-powered, single-SoC pool/aquatic temperature sensor
based on **u-blox NORA-W40** (ESP32-C6, Wi-Fi 6 + Thread + BLE 5.3). It runs
the **esp-matter** stack (Matter over Thread or Wi-Fi) and is optimised for
**multi-year battery life** monitoring stable environments (pool, spa,
aquarium, wine cellar, cold storage).

**Origin:** Forked from the `companion/opencpu/nora-w40-thermometer/` reference
in `u-connectMatter` (May 2026). That project remains as the upstream reference;
AkvaLink is the productised, demo-focused clean-room version.

**Goals:**
- Polished demo for u-blox showcasing single-SoC Matter on NORA-W40
- Real product trajectory (waterproof probe, battery enclosure, multi-year life)
- Optional non-Matter direct-to-app path (BLE or local Wi-Fi, no cloud)

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│              NORA-W40 (ESP32-C6, single SoC)                 │
│                                                              │
│  esp-matter (release/v1.5) ── Matter Temperature Sensor     │
│      ├─ Endpoint 0: Root (commissioning, OTA, descriptors)  │
│      └─ Endpoint 1: Temperature Sensor (cluster 0x0402)     │
│                                                              │
│  Sensor task (ds18b20_task.cpp)                             │
│      ├─ Adaptive sampling (fast 3 s / slow 60 s)            │
│      ├─ Threshold-gated reporting (default 0.25 °C)         │
│      └─ ROM ID + power mode logging                         │
│                                                              │
│  Two sensor paths (compile-time):                           │
│      A) Direct GPIO + 4.7 kΩ pull-up (default, ≤ 5 m)       │
│      B) DS2482-800 I2C bridge (--clickboard, > 5 m runs)    │
└──────────────────────────────────────────────────────────────┘
                              ↓
                Matter over Thread (default, low power)
                Matter over Wi-Fi  (--wifi build, TWT optional)
```

## Hardware

- **MCU module:** NORA-W401 (external antenna) or NORA-W406 (PCB antenna)
- **Dev board:** EVK-NORA-W40 (USB-C, MikroBUS sockets, exposed GPIO)
- **Sensor:** DS18B20 (or DS1822 / MAX31820, all auto-detected)
- **Default GPIO:** GPIO15 for direct 1-Wire (J15.4 on EVK)
- **Click board (optional):** MikroE I2C 1-Wire Click on MikroBUS 1
  (SDA=GPIO6, SCL=GPIO7, DS2482-800 at I2C 0x18)

## Build / flash workflow

```powershell
# Default (Thread, GPIO sensor)
.\akvalink.cmd build
.\akvalink.cmd flash COM62

# Wi-Fi variant
.\akvalink.cmd --wifi build

# DS2482 Click board
.\akvalink.cmd --clickboard build
```

Build runs in **WSL Ubuntu-24.04**, sourcing:
- ESP-IDF v5.5.5 from `~/esp/esp-idf`
- esp-matter release/v1.5 from `~/esp/esp-matter`

**Per-variant build dirs:** each variant builds into its own isolated directory
with its own sdkconfig — `build/thread`, `build/wifi`, `build/ble`, `build/ap`,
`build/station`, `build/sensor` (plus a `-ds2482` suffix for the Click board).
Switching variants therefore needs **no** reconfigure or rebuild; each keeps its
own ccache. `--flash` picks the directory matching the flags. `clean` wipes all
of `build/`.

## Releasing

Two scripts, clean split — `release.py` *prepares*, `publish.py` *ships*:

```powershell
# 1. Prepare (local): test, bump version.txt, build ALL 5 variants → merged
#    0x0 images in dist/, commit + tag. Touches nothing remote.
py -3 scripts/release.py --bump patch

# 2. Ship (remote): push the tag, create the GitHub release and upload the
#    dist/ assets (thread, wifi, ble, ap, station). Re-runnable; never rebuilds.
py -3 scripts/publish.py
```

- `release.py` = **build**, `publish.py` = **upload**. If a GitHub upload
  hiccups, re-run `publish.py` — no rebuild needed.
- `publish.py` needs **no `gh` CLI** — it uses the GitHub REST API with the
  token Git Credential Manager already holds (override via `GITHUB_TOKEN`).
- Each release asset is a single image flashable with
  `esptool --chip esp32c6 write-flash 0x0 akvalink-<variant>-v<ver>.bin`.
- `dist/` is git-ignored; regenerate it any time with `release.py`.

## Power optimisation rules

This is a **battery-powered product**. Every line of code should respect that
— but even the mains-powered demo variants (AP, station) should still save
power when it's free to do so.

- ✅ Adaptive sampling: fast only when temperature is changing
- ✅ Thread SED with 120 s poll period (default) OR Wi-Fi 6 TWT @ 60 s
- ✅ Light sleep enabled, CPU + flash + peripherals power down
- ✅ Report threshold 0.25 °C (4× the 12-bit 0.0625 °C LSB) gates Matter pushes
- ❌ NEVER add `vTaskDelay` busy loops — use event-driven sleeps
- ❌ NEVER leave UART/SPI/I2C powered when not in use
- ❌ NEVER add periodic Matter sends — only on actual temperature change
- ❌ NEVER add cloud connectivity — local Matter or local BLE only

**Dynamic Frequency Scaling (DFS) + light sleep — enabled per variant:**
CPU DFS (10↔160 MHz) is safe on every variant: Wi-Fi/BT/Thread drivers hold
their own `ESP_PM_APB_FREQ_MAX` lock exactly while they need precise radio
timing (TX/RX, SoftAP beacons) and release it otherwise, so the CPU only
runs at 160 MHz when something actually needs it. Full automatic light sleep
(CPU + peripherals fully power off between events) is enabled wherever it's
confirmed compatible:
- **Thread SED (default)** — full light sleep. Officially supported, this is
  the primary battery target.
- **`--station`** — full light sleep. ESP-IDF officially supports automatic
  light sleep with an associated Wi-Fi station; modem sleep handles the radio
  side independently.
- **`--wifi` (Matter-over-Wi-Fi)** — **DFS only, no full light sleep.** Not a
  compatibility issue like SoftAP — it's flash budget: this variant carries
  the full esp-matter/CHIP stack *and* Wi-Fi, and building with full light
  sleep enabled measurably overflowed the OTA app partition by 0x810 bytes.
  Revisit if/when flash headroom allows (see `config/sdkconfig.defaults.wifi`).
- **`--ap` (SoftAP)** — **DFS only, no full light sleep.** SoftAP beacon
  timing isn't confirmed safe with automatic light sleep, and the AP is a
  mains-powered demo target anyway — not worth risking the captive portal
  for. Still gets the free DFS win.
- **`--ble` (standalone GATT)** — full light sleep, but gated behind
  `CONFIG_AKVALINK_BLE_PM` (off by default) pending a PPK2 measurement — see
  `sdkconfig.defaults.ble`. Don't flip this on without measuring first.
- **`--espnow`** — deep sleep between cycles instead (lower floor than light
  sleep); light-sleep PM is deliberately OFF to avoid conflicting with
  `esp_deep_sleep()`.
- New variant? Enable `CONFIG_PM_ENABLE=y` and call `configure_light_sleep()`
  (see `main/app_main.cpp`) unless there's a specific, documented reason not
  to — pass `false` for DFS-only if full light sleep isn't confirmed safe yet.

**Target battery life on 2× AA in pool monitoring (28-29 °C, 0.25 °C threshold):**
- Thread SED: ~12 years
- Wi-Fi disconnect mode: ~9 years
- Wi-Fi TWT @ 60 s: ~1.8 years (always reachable, requires Wi-Fi 6 AP)

## Code conventions

- **Logging:** Use ESP-IDF `ESP_LOGI/W/E(TAG, ...)` — NOT printf
- **Tags:** `ds2482`, `ds18b20`, `app`, `pm` — short, lowercase
- **Sensor task priority:** Low (5) — Matter task is higher (10)
- **Style:** Match existing — 4-space indent, snake_case for C, camelCase for C++ classes
- **Comments:** Explain *why*, not *what*. Code already says what.

## Zero warnings — a hard goal

The build should be **warning-clean**. A new warning is a bug report from the
compiler; treat it as such.

- **Fix at the source, in our code.** e.g. fully initialise structs (a trailing
  `{}` / zeroed member) instead of leaving `-Wmissing-field-initializers`;
  mark deliberate no-ops `(void)x;` or `__attribute__((unused))`; don't leave
  unused functions/variables lying around.
- **Never silence a warning to hide a real problem.** No blanket `-w`, no
  drive-by `#pragma` over our own code. If you suppress, suppress the narrowest
  scope and say *why* in a comment.
- **Third-party / SDK warnings we can't fix** (esp-idf, esp-matter, NimBLE
  headers, managed_components) may be tolerated, but prefer isolating them
  (e.g. a targeted `-Wno-...` on that component only) over accepting them
  project-wide.
- **When you touch a file, leave it warning-clean.** Don't add new warnings;
  clear existing ones in code you're already editing.
- Check the tail of every build for `warning:` before calling a build "done".

## Project web page

Two product landing pages live in `web/`:
- [web/index.html](../web/index.html) — **English** (source of truth)
- [web/index.sv.html](../web/index.sv.html) — **Swedish** translation

Both are self-contained static files (inline CSS, no build step, no dependencies),
publishable as-is via GitHub Pages. A language toggle (EN | SV) links between them.

- **Keep both files in sync — always.** When you change any text, spec, battery
  number, roadmap item, or build variant in `index.html`, you **must** make the
  equivalent change in `index.sv.html` in the same commit. No exceptions.
- **`index.html` is the source of truth.** Edit English first, then carry the
  change to Swedish. The two files are structurally identical; diff them if in doubt.
- **Keep in sync with reality.** When product facts change — specs, battery
  numbers, build variants/flags, roadmap status — update both pages and the README.
- **Stay self-contained.** No frameworks, no external CSS/JS/build tooling. Each
  file opens by double-clicking. Bump the "Last updated" line on changes (both files).
  - **One deliberate exception:** the "⚡ Flash via USB" buttons load
    [ESP Web Tools](https://esphome.github.io/esp-web-tools/) from the `unpkg`
    CDN (`<script type="module" src="https://unpkg.com/esp-web-tools@...">`).
    Implementing Web Serial ESP32 flashing by hand would mean re-inventing
    esptool's flashing protocol in JS — not worth it. Don't add a second CDN
    dependency without a similarly strong reason; keep everything else vendor-free.
- **On brand:** water/pool theme (cyan/teal), plain-spoken, honest — same voice
  as the README. No cloud claims, no vaporware presented as shipping.
- **Look professional and clean — no clutter.** This is a u-blox showcase and a
  real product page, not a hobby project readme. Every icon, emoji, badge, and
  button must earn its place. Prefer one consistent monochrome SVG icon system
  over mixing emoji and SVGs. When adding a new UI element, ask "does this add
  clarity or just noise?" — if it's noise, cut it. Fewer, sharper elements beat
  more decoration.

## Native app ↔ web page — keep in sync (web is primary)

The Flutter companion app lives in `app_flutter/` (iOS/Android/Windows/Linux/
macOS). **The web page (`web/index.html`) remains the most important, primary
surface** — it's the public landing page and the zero-install way to use the
product. The app is a convenience layer on top; it must never drift ahead of the
web page in a user-visible way.

- **Any user-facing improvement made in the app MUST also be made on the web
  page — in the same change.** New feature, wording, spec, battery number, OTA
  behaviour, version bump, layout idea: if a user would see it in the app, mirror
  it on `web/index.html` (and its Swedish twin `index.sv.html`).
- **Web first, or web-in-lockstep.** Prefer landing a change on the web page
  first (or simultaneously). Never ship an app feature that makes the web page
  look stale or wrong. If something genuinely can't exist on the web (e.g. a
  platform-only capability), say so explicitly in the PR/commit.
- **Version stays aligned.** `app_flutter/pubspec.yaml` `version:`, the web
  page's version badge/footer, and `version.txt` all track the same release.
  Bump them together.
- **Same voice & theme.** The app reuses the web palette (deep `#033f63`, water
  `#0aa2c0`, foam) and the same plain-spoken, no-cloud tone. Keep them one product.
- **EN + SV both.** The app is localized EN/SV just like the web page; when you
  add or change a string in one, update the other (see `app_flutter/lib/strings.dart`
  and the `spellcheck_test.dart` that guards it).

## BLE GATT contract — `main/ble_gatt.cpp` is the source of truth

The standalone `--ble` variant's GATT table (services, characteristics,
UUIDs) is consumed by four independent places: the firmware itself, the
web page's Web Bluetooth code, the Flutter app's `akvalink_uuids.dart`, and
`scripts/ble_gatt_client.py` (the debug tool). They **will** drift if edited
by hand in isolation — there is no shared codegen, just four files that
happen to agree today.

- **`main/ble_gatt.cpp` defines the contract; everything else follows it.**
  If you add, remove, or renumber a characteristic there, update all three
  consumers in the same change: `web/index.html` + `index.sv.html`,
  `app_flutter/lib/ble/akvalink_uuids.dart`, and `scripts/ble_gatt_client.py`.
- **[tests/test_ble_uuids.py](../tests/test_ble_uuids.py) enforces this.**
  It extracts the UUIDs straight out of `main/ble_gatt.cpp` and asserts the
  web page, the app, and the debug script all use the same values. Run the
  full suite (`pytest`) before committing a GATT change — a mismatch there
  means a phone will silently fail to find a characteristic in the field.
- **Current service shape** (services, UUIDs, NVS-backed vs. stubbed
  values) is documented in [docs/CONNECTIVITY.md](../docs/CONNECTIVITY.md)
  under "Mode 3 — Standalone BLE GATT". Update that table whenever the
  contract changes — it's meant to reflect the real firmware, not a
  proposal.
- **Known gap:** the custom AkvaLink service (uptime, writable device name,
  alert thresholds) is implemented in firmware and visible to the debug
  script, but neither the web page nor the app read/write it yet. Don't
  silently "complete" this without being asked — it's a deliberate
  KISS-scoped gap, not a bug — but keep it in mind as the natural next
  BLE feature to wire up end-to-end.

## Software bill of materials (SBOM) — keep it synced with the real toolchain

`web/index.html` + `index.sv.html` have a "Software bill of materials" /
"Programvarukomponenter" section (id="bom", right after Security) listing
the exact versions of ESP-IDF, esp-matter/connectedhomeip, OpenThread,
lwIP, mbedTLS, and NimBLE baked into a release. It exists so a user can
cross-check CVEs themselves — a stale or wrong version number there is
worse than not having the table at all.

- **Whenever the toolchain is bumped** (ESP-IDF, esp-matter, or a
  `idf_component.yml` pin), re-verify every row — don't assume a single
  version bump only touches one line, since lwIP/mbedTLS/OpenThread/NimBLE
  are all pinned by the ESP-IDF release itself. Re-derive them straight
  from the actual WSL toolchain checkout, don't guess from changelogs:
  ```bash
  # ESP-IDF version
  cd ~/esp/esp-idf && git describe --tags
  # esp-matter version/branch
  cd ~/esp/esp-matter && git branch --show-current
  # mbedTLS
  grep -m1 MBEDTLS_VERSION_STRING ~/esp/esp-idf/components/mbedtls/mbedtls/include/mbedtls/build_info.h
  # lwIP
  grep -E 'LWIP_VERSION_(MAJOR|MINOR|REVISION) ' ~/esp/esp-idf/components/lwip/lwip/src/include/lwip/init.h
  # OpenThread / NimBLE (no clean semver upstream — report as
  # "bundled with ESP-IDF v<x>", don't publish a raw commit hash)
  ```
- **Update both `web/index.html` and `index.sv.html` in the same change** —
  same rule as everywhere else on this page (see "Native app ↔ web page"
  above). The table rows must stay word-for-word numerically identical
  between languages; only the surrounding prose is translated.
- **[tests/test_web.py](../tests/test_web.py)** (`test_sbom_versions_match_toolchain_docs`)
  cross-checks the ESP-IDF and esp-matter version strings shown in the BOM
  table against the canonical strings in this file (the "Build / flash
  workflow" section above) — a mismatch there fails CI. lwIP/mbedTLS/
  OpenThread/NimBLE aren't tracked as strings anywhere else in the repo, so
  they have no automated check — re-verify those by hand per the commands
  above whenever the toolchain changes.

## Future direct-to-app path (planned)

A non-Matter path is planned for direct app integration without a hub:
- **Option A:** BLE GATT service (custom UUID) — works without any router
- **Option B:** Local Wi-Fi mDNS + JSON over HTTP — works offline on LAN
- **NO cloud** — the value of the product is local, private monitoring

This is on the roadmap, not implemented yet. Keep code clean enough that it
can be added without ripping out Matter.

**Provisioning for the standalone modes:** support both **Espressif Unified
Provisioning** (default, in-tree, free "ESP BLE Provisioning" app) and
**Nordic Wi-Fi Provisioner** GATT service (re-implemented on ESP-IDF) so we
play well with both silicon ecosystems. Full design in
[docs/CONNECTIVITY.md](../docs/CONNECTIVITY.md).

## u-blox docs MCP server

`.vscode/mcp.json` exposes `mcp_u-blox-docs_search_u_blox_knowledge_sources`
for live verification of NORA-W40 specs, ESP32-C6 features, etc.

**Use it before guessing hardware facts.** First use: VS Code Command Palette
→ MCP: List Servers → start `u-blox-docs` → sign in (Google or GitHub).

## What this project is NOT

- ❌ A reference platform (use `u-connectMatter` for that)
- ❌ A multi-MCU system (ucxclient, NORA-W36, STM32 host — none of that)
- ❌ A cloud product
- ❌ A general-purpose IoT framework — it does ONE thing well

## Other silicon (NORA-B2) — parked, not now

A NORA-B2 (Nordic nRF54L, Zephyr/nRF Connect SDK) port is a real, decided
future direction — see the "Other silicon families" section in
[TODO.md](../TODO.md) for the full feasibility notes and spike plan. **It is
on hold until NORA-W40 is fully working** (current EVK power measurement
still open). Don't start any NORA-B2 code, Kconfig, or a new `AkvaLink-nRF`
repo unless explicitly asked — this is a parking-lot item, not work in flight.

## KISS — keep it simple, stupid

The roadmap docs (TODO, CONNECTIVITY, ENCLOSURE_DESIGN, RF_AND_ANTENNA,
WINTER_STORAGE_MODE, EINK_DISPLAY_PLAN) capture **ideas for the future**.
They are deliberately ambitious. Day-to-day code work is the opposite:
small, boring, one thing at a time.

Rules of engagement when implementing in this repo:

- **Implement only what was asked.** No bonus features, no "while I'm
  here" refactors, no speculative abstractions. The roadmap is the
  parking lot for ideas; the code is for the *one* idea being shipped.
- **Pick exactly one thing in flight.** Power tuning **OR** e-ink **OR**
  BLE-only — never two of them in the same change. If a request implies
  more than one, ask which to start.
- **Smallest viable diff wins.** Prefer extending an existing file over
  adding a new one. Prefer 30 lines over 300. Prefer a Kconfig flag
  over a new abstraction layer.
- **No new docs unless asked.** When you find a new idea or constraint
  while coding, add it as a bullet to the relevant existing doc — do
  not spawn a new `*.md`.
- **No new dependencies without checking first.** If a feature seems to
  need a new component, ask before pulling it in.
- **Measure before optimising.** Power, RF, battery — don't add code to
  "save power" without a baseline number to beat.
- **Hardware first, polish second.** Until the EVK + DS18B20 actually
  reads temperature in someone's hand and shows up in Apple Home, every
  other feature is theoretical and lower priority.
- **When in doubt: do less.** A working v0 beats a perfect v1 that never
  ships. The roadmap will still be there next week.

## Lessons inherited from `u-connectMatter`

- Windows .cmd files MUST be CRLF — `.gitattributes` enforces this
- PowerShell `Get-Content` defaults to ANSI — use `-Encoding UTF8` for source
- Hardware claims need a verified source (datasheet, schematic) — never guess
- Do not pipe long-running commands through `| Out-String` (buffers output)
- Commit and tag when something works — easy to roll back from a known-good

## Have fun

This is u-blox showcase material. Make the demo delightful:
- ASCII banner at boot with a  / 💧 emoji
- ANSI colors in logs for state transitions (heating ↑ red, cooling ↓ blue)
- Memorable startup line: `[AkvaLink] Online · pool · 28.4 °C · battery 87%`

Where fun does NOT belong: error logs, crash paths, hot loops.
