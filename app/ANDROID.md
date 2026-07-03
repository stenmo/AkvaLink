# Build AkvaLink for Android

Android needs **no Mac** — build on Windows, WSL, or macOS. The scaffold, BLE
shim, and Android permissions are already wired up; you just add the platform
and run.

## One-time setup

1. **Tools**
   - **Android Studio** (includes the Android SDK) — open it once and let it
     install the SDK + platform-tools.
   - **JDK 17** — Android Studio bundles one, or install Temurin 17.
   - **Node LTS**: `nvm install --lts` (or from nodejs.org).

2. **Code + native project**
   ```bash
   cd app
   nvm use                # Node LTS (.nvmrc)
   npm install
   npm run add:android    # cap add android
   ```

## Build & run (repeat each time)

```bash
npm run cap:android      # build web → sync → open Android Studio
```

In Android Studio:
1. Enable **USB debugging** on your phone (Settings → Developer options).
2. Plug it in and pick it as the run target.
3. Press **▶ Run**.

## Permissions (automatic)

The `@capacitor-community/bluetooth-le` plugin auto-merges `BLUETOOTH_SCAN` /
`BLUETOOTH_CONNECT` into the manifest — **no editing needed**. On Android 12+
the "Nearby devices" permission is requested at **runtime** on the first
connect (expected). The shim calls `initialize({ androidNeverForLocation: true })`
so no location permission is asked for.

## Test it

Tap **Connect via Bluetooth** → pick your AkvaLink → live temperature + the
firmware-version line should appear. BLE needs a **real phone** (not the
emulator).

## Good to know

- **App icon** is generated from [`../web/favicon.svg`](../web/favicon.svg) by
  `scripts/android-icon.mjs` (runs inside `add:android` and `cap:android`) — it
  writes all launcher densities plus the adaptive icon, matching the iOS app.
  Change the favicon and re-run `npm run android:icon` to refresh it.
- **"Flash latest firmware"** needs same-origin firmware the app doesn't bundle;
  **live temperature** and **manual `.bin` OTA** are the app's BLE paths.
- Re-run `npm run cap:android` after any change in `../web/**` (it regenerates
  and re-syncs the UI).
- If a connect misbehaves, it's a small tweak in [`src/ble-shim.js`](src/ble-shim.js);
  watch **Logcat** in Android Studio for `[BLE] …` / `[OTA] …` lines.
