# AkvaLink app (Flutter)

Native companion app for the **AkvaLink** battery-powered Matter pool &
aquatic temperature sensor (u-blox NORA-W40 / ESP32-C6).

Same look & feel as the [web landing page](../web/index.html), but focused on
the two things that matter in the hand:

1. **Live temperature** — connect over Bluetooth and watch the reading update.
2. **Firmware updates** — one-click OTA that auto-selects the right release
   asset for the connected device's variant.

Runs on **iOS, Android, Windows, Linux and macOS** from one codebase.

## Why Flutter (not Flet)

This app reuses the exact stack proven in `u-connectXplorer`:
[`universal_ble`](https://pub.dev/packages/universal_ble) for cross-platform
BLE, `provider` for state, `http` for GitHub release fetching. Flutter gives a
single pixel-identical UI on all five platforms with native BLE — Flet's BLE
story across desktop + mobile is far weaker.

## How it works

The app speaks the same GATT contract as the firmware
(`main/ble_gatt.cpp`, `main/ble_escape.cpp`):

| Purpose            | Service                        | Characteristic |
|--------------------|--------------------------------|----------------|
| Live temperature   | Environmental Sensing `0x181A` | `0x2A6E` (sint16, 0.01 °C, notify) |
| Firmware revision  | Device Information `0x180A`     | `0x2A26` → `"{version}-{variant}"` |
| Battery level      | Battery Service `0x180F`        | `0x2A19` (uint8 %) |
| OTA control        | `f0a00001-…-0010`              | `…-0011` (write + notify status) |
| OTA data           | `f0a00001-…-0010`              | `…-0012` (write firmware chunks) |

The **Firmware Revision** string carries the variant (e.g. `0.3.1-thread`),
so the app fetches `akvalink-thread-app-v0.3.1.bin` from the newest GitHub
release and flashes the matching image automatically — no manual variant
picking.

OTA protocol: write `0x01` (BEGIN, device erases the passive slot) → stream the
image to the data characteristic in MTU-safe chunks → write `0x02` (END, device
finalises and reboots). `0x03` aborts.

## Build & run

From the repo root, the unified launcher handles the app on any host:

```powershell
# Windows
..\akvalink.cmd --app              # build the Windows app
..\akvalink.cmd --app --android    # build the Android APK
..\akvalink.cmd --app --run        # run on this machine
```

```bash
# Linux / macOS
../akvalink.sh --app               # build for this host
../akvalink.sh --app --macos       # macOS app (on a Mac)
../akvalink.sh --app --ios         # iOS app (on a Mac)
../akvalink.sh --app --android     # Android APK
../akvalink.sh --app --run         # run on this machine
```

Or drive Flutter directly from this folder:

```powershell
flutter pub get

# Desktop
flutter run -d windows      # or -d linux, -d macos

# Mobile (device/emulator attached)
flutter run -d android
flutter run -d ios          # macOS + Xcode required

# Release builds
flutter build windows
flutter build apk
flutter build linux
flutter build ipa           # macOS + Xcode required
```

## Tests

```powershell
flutter test
```

Coverage:
- `test/ble_controller_test.dart` — scanning (name/service match, strongest
  RSSI, none-found), connect/disconnect, temperature decode (incl. negative &
  malformed), device-info reads, and **link-drop** handling. Driven by an
  in-memory `FakeBlePlatform` (`test/fakes/`).
- `test/ota_controller_test.dart` — release-asset selection, happy-path
  BEGIN→stream→END, and corner cases: device-reported error, dropped link
  mid-upload, missing asset, bad download, busy-guard, local-file flash.
- `test/spellcheck_test.dart` — every UI string (EN + SV) screened against a
  hand-curated dictionary, plus parity, whitespace and misspelling checks.
- `test/firmware_parse_test.dart` — firmware-revision → version/variant parsing.

## Versioning

`pubspec.yaml` `version:` tracks the firmware `../version.txt`. Bump both
together when cutting a release so "On device" vs "app expects" line up.

## Permissions

- **Android** — `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` (API 31+, `neverForLocation`),
  legacy `BLUETOOTH*` + fine location on ≤ API 30. Declared in the manifest.
- **iOS / macOS** — `NSBluetoothAlwaysUsageDescription` + Bluetooth &
  network-client entitlements.
- **Windows / Linux** — no manifest permissions needed; `universal_ble` uses
  the OS BLE stack directly.

## Layout

```
lib/
  main.dart                     app entry, providers, theme wiring
  theme.dart                    colours + light/dark themes (mirror web palette)
  ble/
    akvalink_uuids.dart         the GATT contract (UUIDs + OTA opcodes)
    akvalink_controller.dart    scan → connect → temperature/battery/firmware
  ota/
    ota_controller.dart         OTA flow + GitHub release asset selection
  screens/
    home_screen.dart            hero + temperature + OTA
  widgets/
    hero_header.dart            water-gradient brand band
    temperature_card.dart       big live readout + connect button
    ota_card.dart               firmware update card
```

No cloud, ever — local Bluetooth only.
