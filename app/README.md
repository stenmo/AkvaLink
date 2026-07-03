# AkvaLink app (Capacitor)

A thin **native iOS/Android** wrapper around the existing AkvaLink landing page
([`../web/index.html`](../web/index.html)). It exists for one reason: **iOS has
no Web Bluetooth** in any browser, so the in-browser "See it live" + OTA flow
can't run on an iPhone. This app runs the *same UI* in a native WebView and
provides Bluetooth through the native [`@capacitor-community/bluetooth-le`](https://github.com/capacitor-community/bluetooth-le)
plugin via a small `navigator.bluetooth` shim — so the web code runs unchanged.

```
web/index.html  ──(scripts/build-web.mjs)──►  index.html + src/page.js
                                                        │
        src/ble-shim.js  (navigator.bluetooth → BleClient)
                                                        │
                          Vite build ──► dist/ ──► Capacitor ──► iOS / Android
```

- **`web/` stays the single source of truth.** `index.html` and `src/page.js`
  here are **generated** (git-ignored); edit the page in `web/`, then rebuild.
- Only `package.json`, `capacitor.config.json`, `vite.config.js`,
  `scripts/build-web.mjs`, `src/ble-shim.js`, `src/main.js` are committed.

## Prerequisites

- **Node.js 18+** and npm.
- **iOS:** macOS + Xcode + CocoaPods (`sudo gem install cocoapods`). iOS builds
  are **Mac-only** — you cannot build the iOS app on Windows.
- **Android:** Android Studio + JDK 17 (works on Windows/macOS/Linux).

## First-time setup

```bash
cd app
nvm use                # Node LTS (see .nvmrc)
npm install
npm run build          # regenerates index.html+page.js from ../web, bundles to dist/

# add the native projects (creates ios/ and/or android/, git-ignored)
npm run add:ios        # macOS: cap add ios + auto-adds the Bluetooth Info.plist keys
npm run add:android    # cap add android
```

## Build & run

```bash
npm run cap:ios        # build web + sync + open Xcode  (then Run on device)
npm run cap:android    # build web + sync + open Android Studio
```

After any change to `../web/**`, re-run `npm run cap:sync` (or `cap:ios` /
`cap:android`) to regenerate and copy the UI into the native project.

## Permissions (automated)

- **iOS** — `scripts/ios-permissions.mjs` adds the required Bluetooth usage
  strings (`NSBluetoothAlwaysUsageDescription` +
  `NSBluetoothPeripheralUsageDescription`) to `ios/App/App/Info.plist`. It runs
  automatically via `npm run add:ios` and every `npm run cap:ios`, and is
  idempotent — **no manual plist editing needed**.
- **Android** — the plugin merges `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT`
  automatically. The shim calls `initialize({ androidNeverForLocation: true })`
  so no location permission is requested (BLE-only, Android 12+).

## What works / what doesn't (v1)

- ✅ **Live temperature** over BLE (ESS `0x181A` / `0x2A6E`), reconnect to a
  remembered device, firmware-version read (DIS `0x2A26`).
- ✅ **OTA via manual `.bin` pick** (the custom OTA GATT service).
- ⚠️ **"Flash latest firmware"** fetches a same-origin image the *web* Pages
  site stages; the app doesn't bundle firmware, so that button falls back to
  "no published firmware — pick a .bin". Live temp + manual OTA are the app path.
- ⚠️ **Not yet tested on a device.** This is a scaffold generated on a Windows
  box without Node; validate `npm run build` and a real BLE connect on your Mac
  / Android machine, and tweak `src/ble-shim.js` if the plugin API drifts.

## How the shim works

`src/ble-shim.js` defines `navigator.bluetooth` **only** on a native platform
(`Capacitor.isNativePlatform()`), mapping the Web Bluetooth subset the page uses
onto `BleClient`:

| Web Bluetooth | BleClient |
|---------------|-----------|
| `requestDevice({filters:[{namePrefix}], optionalServices})` | `BleClient.requestDevice(...)` |
| `gatt.connect()` / `disconnect()` | `connect(id, onDisconnect)` / `disconnect(id)` |
| `getPrimaryService` / `getCharacteristic` | (uuids normalised to 128-bit) |
| `readValue()` → DataView | `read(...)` |
| `writeValue` / `writeValueWithoutResponse` | `write` / `writeWithoutResponse` |
| `startNotifications` + `characteristicvaluechanged` | `startNotifications(..., cb)` |
| `getDevices()` (reconnect) | `getDevices([lastId])` (id kept in `localStorage`) |

In a real browser the shim is inert and the page uses the browser's own
Web Bluetooth.
