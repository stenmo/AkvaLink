# Build AkvaLink for iPhone — on a Mac

The scaffold, BLE shim, and iOS Bluetooth permissions are already wired up. On
the Mac you only **add the platform and run** — everything below is Mac-only
because it needs Apple's toolchain (Xcode).

## One-time setup

1. **Tools**
   - **Xcode** (App Store) — open it once to accept the license.
   - **CocoaPods**: `sudo gem install cocoapods`
   - **Node LTS**: `nvm install --lts` (or from nodejs.org)

2. **Code + native project**
   ```bash
   cd app
   nvm use                # Node LTS (.nvmrc)
   npm install
   npm run add:ios        # cap add ios + auto-adds the Bluetooth Info.plist keys
   ```

## Build & run (repeat each time)

```bash
npm run cap:ios          # build web → sync → patch permissions → open Xcode
```

In Xcode:
1. Select the **App** target → **Signing & Capabilities** → pick your **Team**
   (your Apple ID). If `com.akvalink.app` is taken, change the Bundle Identifier.
2. Plug in your **iPhone** and choose it as the run destination.
3. Press **▶ Run**. First run only: on the iPhone go to
   **Settings → General → VPN & Device Management** and trust your dev cert.

## Test it

Tap **Connect via Bluetooth** → pick your AkvaLink → live temperature + the
firmware-version line should appear. BLE needs a **real iPhone** (not the
simulator).

## If a connect misbehaves

The whole build pipeline is proven; a device issue would be a small tweak in
[`src/ble-shim.js`](src/ble-shim.js) (UUID format or the notification callback).
Watch the **Xcode console** for `[BLE] …` and `[OTA] …` log lines.

## Good to know

- **App icon** isn't set yet — add later with `@capacitor/assets`.
- **"Flash latest firmware"** needs same-origin firmware the app doesn't bundle;
  **live temperature** and **manual `.bin` OTA** are the app's BLE paths.
- Re-run `npm run cap:ios` after any change in `../web/**` (it regenerates and
  re-syncs the UI).
