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

### Service shape (proposed)

Vendor-specific 128-bit UUID under a u-blox base, with these
characteristics:

| Characteristic | Properties | Payload |
|----------------|-----------|---------|
| Temperature | Read, Notify | int16 `°C × 100`, little-endian |
| Battery level | Read, Notify | uint8 `%` (0–100) |
| Mode / status | Read | bit field: in-water, low-battery, storage-mode, etc. |
| Identify | Write | Triggers a display flash (UX confirmation) |
| Set threshold | Write | int16 `°C × 100`, persisted to NVS |
| History (optional) | Read | last N hourly samples for the in-app graph |

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
- Exposes:
  - **mDNS** record `_akvalink._tcp.local`.
  - **HTTP server** on `:80` with two endpoints:
    - `GET /api/v1/sensor` → JSON `{ "temp_c": 28.4, "battery_pct": 87, "rssi": -52, "uptime_s": ... }`.
    - `GET /` → minimal HTML/PWA dashboard for phone browsers.
  - Optional **MQTT publish to a user-configured local broker** (off by
    default; turn on for Home Assistant integration).
- Same disconnect-mode trick as Matter-over-Wi-Fi for battery.

**Why offer it:** Home Assistant / Node-RED / integrator scenarios.
Plus, an `_akvalink._tcp.local` device on the LAN is friction-free:
no app, no account, just `http://akvalink.local`.

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

| Provisioner | Phone apps | Pros | Cons | Recommendation |
|-------------|-----------|------|------|----------------|
| **Espressif Unified Provisioning** (`wifi_provisioning`, "Improv-style") | **ESP BLE Provisioning** (Espressif, iOS+Android) | Already in ESP-IDF — zero extra deps. App is published, free, works. Same component used by every recent ESP32 product. Supports BLE *and* SoftAP transports, security2, custom data hooks. | Espressif-branded app; not a household name. | **v1 default.** |
| **Nordic Wi-Fi Provisioner** | **nRF Wi-Fi Provisioner** (Nordic, iOS+Android) | Polished UX. Documented BLE GATT service spec — implementable on any chip. nRF Connect ecosystem is recognisable to BLE engineers. | Spec is Nordic-flavoured; we re-implement the GATT service on ESP-IDF (it's not a drop-in component). Splits dev effort if we also do Espressif. | **v1.1 add-on**, behind a build flag. Useful "we play well with both ecosystems" story. |
| Improv-Wi-Fi (Home Assistant) | Any browser via Web Bluetooth | App-less. Open spec. | Slightly more limited feature set. | Nice-to-have v1.1 — same GATT-shaped problem as Nordic. |
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

**Why both Espressif *and* Nordic eventually:** AkvaLink is a u-blox
showcase. Demonstrating that the device is provisionable from *both*
ecosystems' standard apps is a credible "we sit above the silicon
politics" story — and it costs us nothing once the BLE GATT
infrastructure for mode 3 is in place.

### Provisioning flow (modes 3 & 4)

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

## Roadmap (this is the order)

1. Matter / Thread — *shipped*.
2. Matter / Wi-Fi — *shipped, needs disconnect-mode + TWT polish*.
3. **BLE-only standalone** + tiny GATT service + manufacturer-data beacon.
4. **Wi-Fi standalone** + Espressif Unified Provisioning over BLE
   + mDNS + HTTP/JSON. *(Espressif is the chosen provisioner.)*
5. Nordic Wi-Fi Provisioner GATT service — *optional*, only for the
   dual-ecosystem demo story; skip unless that's wanted.
6. Universal build with runtime mode select.
7. Optional Improv-Wi-Fi for Home Assistant friendliness.

Tracked in [TODO.md](../TODO.md) under **Connectivity / Provisioning**.
