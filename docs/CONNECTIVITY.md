# Connectivity Strategy

> AkvaLink supports **multiple ways to talk to your phone**, picked at
> commissioning time. The hardware (NORA-W40 = Wi-Fi 6 + Thread + BLE 5.3)
> can do all of them — the firmware exposes them as four selectable modes
> so the user keeps the choice.

The product positioning is "drop it in the pool and forget it" — and the
single biggest barrier to that is the phrase *"requires a hub"*. So we
support both the standards path (Matter) **and** standalone paths (BLE,
Wi-Fi) with no cloud in any of them.

---

## The four modes

| # | Mode | Stack | Needs a hub? | Range | Battery cost | Best for |
|---|------|-------|--------------|-------|--------------|----------|
| 1 | **Matter over Thread** | esp-matter + OpenThread | Yes — Thread Border Router (HomePod mini, Apple TV 4K, Nest Hub gen 2, Echo Hub) | Mesh, very good | **Best** (target ~12 yr on 2× AA) | Default for users with a modern smart home |
| 2 | **Matter over Wi-Fi** | esp-matter + Wi-Fi 6 (TWT/DTIM) | Wi-Fi 6 AP for full TWT win, otherwise any AP + a Matter controller | Wi-Fi range | Good with TWT, OK with disconnect-mode | Houses with no Thread BR, but a Wi-Fi 6 AP and a Matter controller |
| 3 | **Standalone BLE GATT** | NimBLE | **No.** Direct phone ↔ device. | ~10 m line of sight | Very low (advertise only when interested) | Holiday home, rental, no smart home at all |
| 4 | **Standalone Wi-Fi** | LwIP + mDNS + tiny HTTP/JSON | Just a Wi-Fi AP (any) | Wi-Fi range | Same envelope as Matter-over-Wi-Fi | Local-network dashboards, Home Assistant, integrators |

Matter modes (1, 2) and standalone modes (3, 4) are mutually exclusive at
runtime — different network stacks, different sleep strategies, different
provisioning UX. The user picks one at commissioning time and can change
it later via a long-press factory-reset.

> **No cloud. Ever.** Every mode is local-only. No vendor MQTT broker,
> no analytics endpoint, no telemetry "for product improvement". This
> is the value proposition; we don't get to compromise on it.

---

## Mode 1 — Matter over Thread *(default, lowest power)*

- Already implemented (`sdkconfig.defaults`, `CHIP_DEVICE_CONFIG_ENABLE_THREAD`).
- Sleepy End Device with poll period 120 s (target 300 s after the
  power-tuning pass — see [TODO.md](TODO.md)).
- Commissioning: BLE → Matter QR code → device joins Thread network via
  the BR's commissioning credentials.
- Wakes only on:
  - Sensor poll cycle.
  - Threshold crossing → push report.
  - Reed-switch / button (winter wake).

**Why default:** Thread mesh + SED is the only path that hits multi-year
battery life with always-reachable behaviour.

## Mode 2 — Matter over Wi-Fi

- Existing build flag (`--wifi`, `sdkconfig.defaults.wifi`).
- Two power sub-modes:
  - **TWT** (Wi-Fi 6 Target Wake Time, ~60 s) — always reachable, ~1.8 yr
    on 2× AA. Needs a Wi-Fi 6 AP that actually negotiates TWT (Asus, Eero
    6E, Unifi U6, recent Apple Express). Most ISP routers don't.
  - **Disconnect-mode** (planned) — wake → associate → push → tear down
    → deep sleep. ~9 yr on 2× AA. Not reachable for read-on-demand
    between cycles.
- Commissioning: same Matter QR → BLE → controller pushes Wi-Fi
  credentials → device associates.

**Why offer it:** plenty of houses have a great Wi-Fi 6 AP and zero
Thread infrastructure. Don't make those users buy a HomePod just to
read a pool temperature.

## Mode 3 — Standalone BLE GATT *(no hub at all)*

The "I just want to use it on a holiday rental" mode. Zero infrastructure.

### Service shape (implemented — `main/ble_gatt.cpp`, NimBLE)

`main/ble_gatt.cpp` is the **source of truth** for this contract. Every
consumer (web page, Flutter app, `scripts/ble_gatt_client.py`) must use the
exact same UUIDs — [tests/test_ble_uuids.py](../tests/test_ble_uuids.py)
extracts the UUIDs from all four places and fails CI if any of them drift.

| Service | Characteristic | UUID | Properties | Payload |
|---------|-----------------|------|-----------|---------|
| Device Information `0x180A` | Manufacturer | `0x2A29` | Read | `"u-blox"` |
| | Model | `0x2A24` | Read | `"AkvaLink NORA-W40"` |
| | Firmware Revision | `0x2A26` | Read | `"{version}-{variant}"` (drives app auto-OTA-asset-select) |
| Environmental Sensing `0x181A` | Temperature | `0x2A6E` | Read, Notify | sint16, 0.01 °C, little-endian |
| Battery `0x180F` | Battery Level | `0x2A19` | Read | uint8 0–100 % (stub `100` until ADC circuit is populated) |
| AkvaLink custom (`f0a00001-…-0001`, 128-bit) | Uptime | `…-0002` | Read | uint32 seconds since boot |
| | Device name | `…-0003` | Read, Write | UTF-8 string, NVS-backed, takes effect next reboot |
| | Alert high | `…-0004` | Read, Write | sint16, 0.01 °C, NVS-backed, `0` = disabled |
| | Alert low | `…-0005` | Read, Write | sint16, 0.01 °C, NVS-backed, `0` = disabled |
| AkvaLink OTA (`f0a00001-…-0010`, 128-bit) | Control | `…-0011` | Write, Notify | `0x01` BEGIN / `0x02` END / `0x03` ABORT; notifies `[opcode, result]` |
| | Data | `…-0012` | Write / Write-no-rsp | Raw firmware chunks, in order |

**Not yet surfaced anywhere but the debug script:** the custom AkvaLink
service (uptime, writable device name, alert thresholds) is fully
implemented in firmware and known to `scripts/ble_gatt_client.py`, but
neither the web page nor the Flutter app read or write it yet. Candidates
for a future pass: expose the alert thresholds and device name as editable
fields in the app, and show uptime as a diagnostic. Battery level is also
still a hard-coded `100 %` stub everywhere until the ADC voltage-divider
circuit is populated (see the roadmap item in [TODO.md](../TODO.md)).

The advertising strategy below (idle beacon / connected notify / event
burst) is still aspirational — see [TODO.md](../TODO.md) for status; only
the always-on legacy + Coded PHY advertising described in
`main/ble_gatt.cpp` is implemented today.

### Advertising strategy (battery-critical)

- **Idle:** advertise once every 1–2 s with a short manufacturer-data
  payload that includes the latest temperature + battery. Apps can read
  the value with **zero connection** ("BLE beacon" mode).
- **Connected:** notifications drop straight into the phone over an
  active GATT link.
- **Awake-on-event** advertising: on a threshold crossing, briefly
  advertise faster (~200 ms) for ~10 s so a nearby phone catches it.

Battery estimate for "1 s advertise + occasional connection": still well
within multi-year on 2× AA, similar envelope to Thread SED.

### Companion app

We don't write one for v1. The expectation is:

- **u-connectXplorer** (u-blox's own BLE app, iOS + Android) — reads the
  GATT services and notifications raw. First choice for the demo: it's a
  u-blox app talking to a u-blox module, so it keeps the whole showcase
  in-ecosystem.
- **nRF Connect** (free, iOS + Android) — equivalent raw BLE explorer, handy
  as a cross-check / for engineers who already have it.
- **A tiny PWA / web-Bluetooth page** served from the AkvaLink GitHub Pages
  (or the device's own Wi-Fi AP in mode 4) — opens in any browser, talks
  GATT directly, no install.
- A real app comes later if the demo lands.

## Mode 4 — Standalone Wi-Fi *(local LAN, no controller)*

- Joins the user's Wi-Fi (provisioned via BLE — see below).
- Exposes (`main/web_page.cpp`, shared verbatim by both `--ap` and
  `--station` — same HTML/JS page, same endpoints, only the network setup
  differs):
  - **mDNS** (`--station` only; `--ap` clients join the SoftAP directly at
    the fixed `192.168.4.1` and don't need discovery) — hostname
    `akvalink-<last4mac>.local`, instance name "AkvaLink temperature",
    `_http._tcp`.
  - **HTTP server** on `:80`:
    - `GET /` → self-contained HTML/JS dashboard (live reading, trend arrow,
      min/max, 24 h/7 d history chart) for any phone/laptop browser.
    - `GET /temp` → `{"celsius": 28.4}` (or `null` before the first reading).
    - `GET /battery` → `{"percent": 87}` (or `null` if unknown).
    - `GET /trend` → `{"direction": "rising"|"stable"|"falling", "delta_c_per_min": 0.02}`
      from the last 5 readings.
    - `GET /stats` → `{"min": 26.10, "max": 29.80, "since_s": 3600}` since boot.
    - `GET /history` → `{"minute": [...], "hourly": [...]}` — 288 entries at
      5-min resolution (24 h) + 168 entries at 1-hr resolution (7 d),
      RAM-only ring buffers, reset by `POST /history/reset`. **Not persisted
      across reboot/OTA/power loss** — see the note below on why.
    - `GET /mqtt-status` → `{"connected": true|false}` (`--station` only).
    - `POST /ota` → raw firmware binary body, flashes the inactive OTA slot
      and reboots (used by `wifi_ota_card.dart` in the Flutter app).
  - Optional **MQTT publish to a user-configured local broker** (`--station`
    only, off by default; turn on for Home Assistant integration).
- Same disconnect-mode trick as Matter-over-Wi-Fi for battery.

**Why offer it:** Home Assistant / Node-RED / integrator scenarios.
Plus, an mDNS-discoverable device on the LAN is friction-free:
no app, no account, just `http://akvalink-<last4mac>.local`.

**Why `/history` isn't flash-persisted:** the ring buffers are tiny
(288 + 168 floats ≈ 1.8 KB), but `--ap`/`--station` are mains-powered
demo targets that rarely reboot, and the battery-critical Thread SED
variant doesn't run this HTTP server at all (Matter attribute reporting
covers it, and a hub/Home app already retains its own history). Adding
NVS wear-levelled persistence for ~1.8 KB that's lost only on the rare
reboot isn't worth the flash-wear complexity — revisit only if a real
use case needs history to survive a power cycle.

The Flutter companion app consumes `/temp`, `/trend` and `/stats` (trend
arrow + min/max, matching the device's own page) over this same Wi-Fi path,
but not yet `/history` (the sparkline chart) — and BLE mode (3) doesn't
expose any of this at all (`main/ble_gatt.cpp` only has the live temperature
characteristic). See [docs/KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).

---

## Provisioning — how the user gets credentials onto the device

This is the bit that breaks first-impressions if you get it wrong.
Choose per mode.

### Matter modes (1, 2)

Already standard: **Matter BLE commissioning**. QR code on the device
label, scan in Apple Home / Google Home / Alexa / `chip-tool`, done.
No alternative needed and no alternative wanted — the whole point of
Matter is that this just works.

### Standalone modes (3, 4) — Wi-Fi credentials over BLE

**Chosen provisioner: Espressif Unified Provisioning** (`wifi_provisioning`)
— it's in-tree, has a free published app, and adds zero dependencies. Nordic
stays a Kconfig-gated *optional* extra (`CONFIG_AKVALINK_PROVISIONER`) only
for the "provisions from both ecosystems" demo story; skip it otherwise.

**Security level: `WIFI_PROV_SECURITY_0`** (plain text, no POP, no crypto
handshake) — chosen over `SECURITY_1` for the simplest possible setup: one tap
in the app, no PIN to type or match. Trade-off: the Wi-Fi password crosses the
air unencrypted during the brief provisioning window. Same trust model already
accepted for the open `--ap` SoftAP — fine for a home network credential on a
hobby/demo device, not a fit for anything higher-stakes. Revisit if a future
custom provisioning UI in the Flutter app wants `SECURITY_1` back.

| Provisioner | Phone apps | Pros | Cons | Recommendation |
|-------------|-----------|------|------|----------------|
| **Espressif Unified Provisioning** (`wifi_provisioning`, "Improv-style") | **ESP BLE Provisioning** (Espressif, iOS+Android) | Already in ESP-IDF — zero extra deps. App is published, free, works. Same component used by every recent ESP32 product. Supports BLE *and* SoftAP transports, security2, custom data hooks. | Espressif-branded app; not a household name. | **v1 default.** |
| **Nordic Wi-Fi Provisioner** | **nRF Wi-Fi Provisioner** (Nordic, iOS+Android) | Polished UX. Documented BLE GATT service spec — implementable on any chip. nRF Connect ecosystem is recognisable to BLE engineers. | Spec is Nordic-flavoured; we re-implement the GATT service on ESP-IDF (it's not a drop-in component). Splits dev effort if we also do Espressif. | **v1.1 add-on**, behind a build flag. Useful "we play well with both ecosystems" story. |
| **Improv** (open spec, [improv-wifi.com](https://www.improv-wifi.com/)) — Serial *or* BLE | Any browser (Web Serial / Web Bluetooth), no app | App-less, open spec. **Serial transport already shipping**: the ESPHome variant ([esphome/akvalink.yaml](../esphome/akvalink.yaml)) enables `improv_serial:`, so ESP Web Tools can flash *and* provision Wi-Fi in the same browser tab over USB. | BLE transport not implemented here; Serial only works while the device is plugged into USB (fine for first-flash, not for later re-provisioning). | Serial: **done** (ESPHome variant only). BLE: nice-to-have v1.1 for the Matter/BLE firmware — same GATT-shaped problem as Nordic. |
| **WPS Push-Button** (WPS-PBC) | Router button + AkvaLink button | App-less, well-known UX. Press WPS on router → long-press button on AkvaLink → paired. Works with most consumer routers. | WPS is officially deprecated in newer Wi-Fi specs and disabled by default on some enterprise APs / Eero / Unifi. WPA3-only networks don't support it. | **v1.1 add-on.** Cheap to add (`esp_wifi_wps_*` is in IDF) and a good fallback for non-technical users with a typical home router. |

> **SoftAP** ("join AkvaLink-XXXX, open `192.168.4.1`") is supported by
> the Espressif provisioning component as a *transport option*, and
> we keep it available for the **laptop-only** case — no phone handy,
> just a browser. Connect the laptop to the AkvaLink AP, open a local
> page, type SSID + password, done. No app install, no Bluetooth.
>
> BLE remains the default for phone users (cleaner UX); SoftAP is the
> "plan B" lever in the same app — and the only path that works when a
> laptop is the only device available. Known rough edges: iOS shows the
> captive-portal mini-browser, Android may drop the AP when it sees no
> internet — both acceptable for a fallback.

> **Why both Espressif *and* Nordic eventually:** AkvaLink is a u-blox
> showcase. Demonstrating that the device is provisionable from *both*
> ecosystems' standard apps is a credible "we sit above the silicon
> politics" story — and it costs us nothing once the BLE GATT
> infrastructure for mode 3 is in place.

### In-app provisioning (Flutter companion app)

The companion app (`app_flutter/`) implements the Espressif Unified
Provisioning BLE client **directly** — no separate "ESP BLE Provisioning"
app install needed for the common case. There's no official Dart/Flutter
client for `wifi_provisioning`/`protocomm`, so this was built from the
ESP-IDF source (`components/wifi_provisioning`, `components/protocomm`):

- **`lib/ble/prov_uuids.dart`** — the provisioning service + 5 characteristic
  UUIDs, derived from `protocomm`'s BLE transport (base 128-bit UUID with the
  fixed 16-bit endpoint ID spliced into bytes 12-13). Documented in the file's
  comments, including the residual risk: derived from the *Bluedroid*
  transport source (`protocomm_ble.c`) since AkvaLink builds on NimBLE
  (`protocomm_nimble.c`, assumed equivalent but not read directly), and not
  yet confirmed against a live device BLE scan.
- **`lib/ble/prov_proto.dart`** — a minimal hand-written protobuf wire codec
  for the six provisioning message types (`session`, `sec0`, `wifi_scan`,
  `wifi_config` + constants), rather than pulling in the `protobuf` package
  and a protoc codegen step for a small, frozen message set.
- **`lib/ble/prov_controller.dart`** — the BLE state machine: scan → connect
  → open a Security0 session → scan Wi-Fi → send SSID/password → poll for
  the join result. Every exchange is write-request-then-read-same-characteristic
  (no GATT notify — `station_web.cpp` doesn't enable it).
- **`lib/screens/wifi_setup_screen.dart`** — the UI, reachable from a "Wi-Fi
  setup" entry on the home screen.

### Finding the device afterwards (mDNS)

BLE provisioning and the HTTP temperature page are **separate subsystems** —
the provisioning GATT service is torn down (`wifi_prov_mgr_deinit()`) the
moment Wi-Fi connects, and the HTTP/mDNS stack only starts afterward
(`start_mdns_and_web()` in `station_web.cpp`). Two tiers get the app from
"just provisioned" to "showing live temperature":

1. **Tier 1 — the BLE-reported IP.** The last provisioning response
   (`RespGetStatus.connected.ip4_addr`) arrives over the still-open BLE link
   right as provisioning succeeds; `ProvController.connectedIp` captures it.
   Good for the very first connection, zero extra dependencies.
2. **Tier 2 — mDNS (`lib/net/station_discovery.dart`).** The station's IP can
   change on a later DHCP renewal, but its mDNS hostname
   (`akvalink-<last4ofmac>.local`, instance name "AkvaLink temperature",
   `_http._tcp`) doesn't. `StationDiscoveryController` resolves a remembered
   hostname directly (fast path), or browses `_http._tcp` on the LAN and
   remembers whichever AkvaLink responds for next time (`multicast_dns`
   package; hostname persisted via `shared_preferences`). Fetches
   `main/web_page.cpp`'s `/temp` JSON directly — no HTML parsing needed.
   Known limitation: the firmware's mDNS instance name isn't per-device, so
   with more than one station on the same LAN the browse picks whichever
   responds first.

### Windows Firewall for mDNS discovery (Windows build only)

The app's `multicast_dns` package opens its own UDP socket on port 5353 —
it does **not** use Windows' built-in mDNS responder (that responder's
`mDNS (UDP-In)` / `mDNS (UDP-Out)` firewall rules are scoped only to
`%SystemRoot%\system32\svchost.exe`, confirmed with
`Get-NetFirewallRule -DisplayName "mDNS (UDP-In)" | Get-NetFirewallApplicationFilter`).
Windows Firewall blocks unsolicited inbound UDP by default, so the first
time `station_discovery.dart` tries to receive mDNS replies, Windows may
show a "Defender Firewall has blocked some features of this app" prompt —
if it's dismissed (or never shown, e.g. running headless), discovery times
out and the UI falls back to manual IP entry (`strings.dart`'s
`provFindingOnLan` message). For reference, Edge, Chrome and Copilot each
ship their **own** dedicated `*(mDNS-In)` rule scoped to their own `.exe` —
the generic system rule never covers third-party apps, so AkvaLink needs
the same treatment.

To add the missing inbound rule by hand (adjust the path — Flutter puts
the Windows build at `app_flutter\build\windows\x64\runner\Release\akvalink.exe`):

```cmd
REM cmd.exe, run as Administrator
netsh advfirewall firewall add rule name="AkvaLink mDNS (UDP-In)" dir=in action=allow protocol=UDP localport=5353 program="C:\path\to\akvalink.exe" profile=private,domain,public
```

```powershell
# PowerShell, run as Administrator
New-NetFirewallRule -DisplayName "AkvaLink mDNS (UDP-In)" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 5353 -Program "C:\path\to\akvalink.exe" -Profile Domain,Private,Public
```

Remove it again with `netsh advfirewall firewall delete rule name="AkvaLink mDNS (UDP-In)"`
or `Remove-NetFirewallRule -DisplayName "AkvaLink mDNS (UDP-In)"`. Not yet
shipped automatically (no installer/MSIX packaging exists to add this rule
for the user) — a Windows-release-path TODO, not a firmware bug.

1. Fresh device (or factory reset): boots into **provisioning advertise**
   mode. E-ink shows: `Pair me — open the app`.
2. User opens the chosen app (Espressif, Nordic, or any GATT browser),
   sees `AkvaLink-XXXX`.
3. App writes:
   - **Mode selection** (3 or 4 — BLE-only or Wi-Fi).
   - **Wi-Fi creds** (if mode 4): SSID, PSK, optional static IP.
   - **Display unit** (°C / °F).
   - **Threshold** override (optional).
4. Device confirms (e-ink: `Paired ✓ Pool · 28.4 °C`), persists to NVS,
   reboots into the chosen mode.
5. Stays provisioned across battery changes (NVS in flash, untouched).

### Re-provisioning / factory reset

- Long-press BOOT/reset for **15 s** → wipe NVS → reboot to provisioning.
- Match the e-ink confirmation to the action ("Factory reset in 5… 4…").
- Same path is used to switch modes (1 → 2 → 3 → 4) later.

---

## How the user picks a mode at the start

Out of the box the device boots into a tiny **mode-select** flow:

```
e-ink shows:
   ┌─────────────────────────────┐
   │  Welcome.                   │
   │  Open the app to pair.      │
   │                             │
   │  [Matter]  [BLE]  [Wi-Fi]   │
   └─────────────────────────────┘
```

The phone app (or the Matter controller's "add accessory" flow) drives
the choice. If the user scans the Matter QR with Apple Home → Matter
mode. If they open ESP BLE Provisioner / Nordic Wi-Fi Provisioner →
they pick BLE-only or Wi-Fi-standalone in the app.

---

## Build matrix

| Target | Build flag(s) | Compiled-in stacks |
|--------|---------------|-------------------|
| Matter / Thread (default) | *(none)* | esp-matter, OpenThread, BLE (commissioning) |
| Matter / Wi-Fi | `--wifi` | esp-matter, Wi-Fi, BLE (commissioning) |
| BLE-only | `--ble` | NimBLE, no Matter, no Wi-Fi, no Thread |
| Wi-Fi AP | `--ap` | Wi-Fi SoftAP, LwIP, HTTP (captive page), no Matter, no BLE |
| Wi-Fi station | `--station` | Wi-Fi STA, LwIP, mDNS, HTTP, MQTT, NimBLE (provisioning), no Matter |
| Sensor test | `--sensor` | 1-Wire only, no radio stacks (bench probe check) |
| **Universal** (eventual goal) | `--all` *(stretch)* | All of the above, runtime mode select. Larger flash, but one SKU. |

The `--all` build is the right end state for a polished product (one
firmware, user picks mode at commissioning). We get there by first
proving each mode in its own slim build, then merging.

---

## Power notes per mode

| Mode | Average current target (idle, stable temp) |
|------|-------------------------------------------|
| Thread SED, 120 s poll | < 30 µA |
| Wi-Fi 6 TWT, 60 s | ~150–250 µA |
| Wi-Fi disconnect-mode, 5 min cycle | < 80 µA |
| BLE advertise, 1 s interval | ~30–60 µA |
| Wi-Fi standalone, 5 min cycle | ~80 µA |
| **Winter storage** (any mode) | < 15 µA |

Numbers are modeled (see [docs/POWER_AND_HARDWARE.md](POWER_AND_HARDWARE.md));
PPK2 verification is on the TODO.

---

## Always-available BLE — investigation (July 2026)

> Question raised: can BLE be **always available on every variant** — either
> by "borrowing" BLE from Matter (coexistence), or by a GPIO-selected dual
> boot into a BLE image on a second flash bank?

**Hardware fact (NORA-W40 datasheet, verified):** one radio, one antenna.
Wi-Fi / 802.15.4 (Thread) / BLE are *time-divided on the antenna* by the
ESP32-C6 coexistence arbiter — the same mechanism Matter already uses to run
CHIPoBLE and Thread "simultaneously" during commissioning. So coexistence is
a supported, documented capability, not a hack.

Three approaches, with the honest trade-offs:

### Option A — BLE always-on, coexisting with Matter/Wi-Fi
Keep the BLE controller + NimBLE host alive *after* Matter commissioning and
register our GATT services alongside CHIPoBLE (Matter normally tears BLE down
post-commission to reclaim RAM/power).
- ✅ Supported; ~30–50 KB RAM/flash cost.
- ❌ **Kills the battery goal for SED/Thread.** BLE advertising forces regular
  radio wake-ups; the ~12 yr on 2× AA figure collapses to months. Violates the
  power rules.
- **Good for mains-powered variants only** (AP / Station / ESPHome) — no battery
  cost there, and it hands every mains variant "talk to it over Bluetooth" free.

### Option B — Dual-boot: GPIO at boot picks a flash bank
Two separate app images in `ota_0` / `ota_1`; a custom bootloader reads GPIO9
(BOOT) and selects the BLE app vs the Matter app.
- ❌ **Breaks OTA** — both slots hold *different* apps, leaving no free slot to
  receive an update (would need a third app partition).
- ❌ **Won't fit on 4 MB** — `ota_0`+`ota_1` already = 3.75 MB and a Matter image
  alone is ~1.9 MB. Needs the **8 MB** module (NORA-W401-10B / W406-10B).
- 🔧 Custom bootloader (`CONFIG_BOOTLOADER_CUSTOM`) — extra complexity + certification cost.
- Verdict: strongest isolation, but overkill unless the two firmwares must be
  fully independent *and* we commit to 8 MB.

### Option C — One image, GPIO at boot selects the stack *(recommended)*
Single firmware compiles **both** paths; `app_main` reads GPIO9 at boot —
held → BLE-only GATT server; released → normal Matter/Wi-Fi path. This is
roadmap item #6 ("Universal build with runtime mode select").
- ✅ No bootloader changes, no partition changes, **OTA stays intact** (one slot
  updates everything).
- ✅ Reuses the existing GPIO9 re-provisioning button — becomes a **BLE escape
  hatch**: if Matter/Thread commissioning is broken, hold BOOT at power-on to
  come up as a plain BLE sensor a phone can read.
- ✅ BLE only runs when *asked for*, so no always-on battery drain.
- ⚠️ **Open question — flash budget.** Matter + Thread + Wi-Fi + NimBLE-GATT in
  one image may not fit in 4 MB (the Thread build is already ~1 % free). **This
  must be measured with `idf.py size` before committing** (per the *measure
  before optimizing* rule). Very likely fits on 8 MB.

**Recommendation:** Option A-lite for the mains variants (always-on BLE, no
battery cost) + Option C for the battery variants (on-demand BLE escape hatch,
gated behind a flash-size measurement). **Not** Option B unless we adopt the
8 MB module. Next concrete step: measure current per-variant flash usage
(`idf.py size` / `size-components`) to settle the Option C 4 MB question.

---


## Roadmap (this is the order)

1. Matter / Thread — *shipped*.
2. Matter / Wi-Fi — *shipped, needs disconnect-mode + TWT polish*.
3. **BLE-only standalone** + tiny GATT service + manufacturer-data beacon.
4. **Wi-Fi standalone** + Espressif Unified Provisioning over BLE
   + mDNS + HTTP/JSON. *(Espressif is the chosen provisioner.)*
5. Nordic Wi-Fi Provisioner GATT service — *optional*, only for the
   dual-ecosystem demo story; skip unless that's wanted.
6. Universal build with runtime mode select.
   *See [Always-available BLE — investigation](#always-available-ble--investigation-july-2026)
   above (Option C — GPIO-at-boot BLE escape hatch). Gate on an `idf.py size`
   flash-budget measurement first.*
7. Optional Improv **BLE** for Home Assistant friendliness (Improv **Serial** already ships on the ESPHome variant — see the provisioning table above).

Tracked in [TODO.md](../TODO.md) under **Connectivity / Provisioning**.
