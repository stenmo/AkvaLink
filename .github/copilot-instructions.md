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
.\launch-akvalink-wsl.cmd build
.\launch-akvalink-wsl.cmd flash COM62

# Wi-Fi variant
.\launch-akvalink-wsl.cmd --wifi build

# DS2482 Click board
.\launch-akvalink-wsl.cmd --clickboard build
```

Build runs in **WSL Ubuntu-24.04**, sourcing:
- ESP-IDF v5.4.1 from `~/esp/esp-idf`
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

This is a **battery-powered product**. Every line of code should respect that.

- ✅ Adaptive sampling: fast only when temperature is changing
- ✅ Thread SED with 120 s poll period (default) OR Wi-Fi 6 TWT @ 60 s
- ✅ Light sleep enabled, CPU + flash + peripherals power down
- ✅ Report threshold 0.25 °C (4× the 12-bit 0.0625 °C LSB) gates Matter pushes
- ❌ NEVER add `vTaskDelay` busy loops — use event-driven sleeps
- ❌ NEVER leave UART/SPI/I2C powered when not in use
- ❌ NEVER add periodic Matter sends — only on actual temperature change
- ❌ NEVER add cloud connectivity — local Matter or local BLE only

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
- **On brand:** water/pool theme (cyan/teal), plain-spoken, honest — same voice
  as the README. No cloud claims, no vaporware presented as shipping.

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
- ASCII banner at boot with a 🏊 / 🌊 / 💧 emoji
- ANSI colors in logs for state transitions (heating ↑ red, cooling ↓ blue)
- Memorable startup line: `[AkvaLink] Online · pool · 28.4 °C · battery 87%`

Where fun does NOT belong: error logs, crash paths, hot loops.
