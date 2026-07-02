# Winter Storage Mode — Design Notes

> *"Drop it in the pool → it just reconnects. Even after winter, it just works."*

This is the single feature that separates "smart pool thermometer" from
"another battery you have to remember to replace". It is also where most
consumer IoT quietly fails: a normal "low power" device burns 30–100 µA
in idle and dies over a Swedish winter. We need a **separate operating
mode**, not just a longer sleep.

---

## Goals

- **Survive 3–6 months** of unattended storage (garage, shed, basement).
- **< 10–15 µA average** current draw.
- **No random wake-ups** that quietly drain the battery.
- **Clean recovery** — drop it in the pool in spring and it rejoins Matter
  on its own, no app dance, no recommissioning.

A pair of lithium AAAs at ~1000 mAh divided by 12 µA gives ~9 years of
storage budget. So the math is fine *if* we actually hit 12 µA.

---

## Triggering storage mode

### Option 1 — Explicit (recommended for v1)

Two equally valid triggers, support both:

- **Long press of the BOOT button** (≥ 5 s) before putting the device away.
  The boot banner already mentions battery state; show a clear
  `[AkvaLink] Entering winter storage. Press button to wake.` line.
- **Matter command** — a custom cluster command, or simply piggy-back on
  the OnOff cluster Off command if we add one. *Nice touch:* user can
  send the device to sleep from the Home app before going on holiday.

### Option 2 — Automatic detection

Conditions:
- No temperature change > 0.1 °C for N hours (e.g. 24 h).
- No Matter subscription activity for N hours.
- Battery voltage above some sanity threshold (avoid storing a near-dead
  cell, which then dies completely).

**Don't ship this in v1.** False triggers are a support nightmare —
imagine the device entering storage mode in midsummer because the pool
temperature genuinely flatlined for a day. Build the explicit path
first, instrument it, then *maybe* layer auto-detect on top with a
generous timeout (e.g. 7 days flat + 7 days no controller).

---

## What gets shut down

In storage mode, kill **everything**:

- Thread stack (`otIp6SetEnabled(ot, false)` then `otThreadSetEnabled(ot, false)`).
- Wi-Fi station + SoftAP (`esp_wifi_stop` + `esp_wifi_deinit`).
- BLE (`esp_bt_controller_disable` + `esp_bt_controller_deinit`).
- Sensor power (DS18B20 VCC GPIO low; see below).
- E-ink panel power (P-MOSFET off; show a final "Stored — wake by button"
  splash first, then cut power — image persists for free).
- All periodic timers and the sensor task.

Then:
```c
esp_sleep_enable_ext1_wakeup_io(BIT64(BUTTON_GPIO) | BIT64(REED_GPIO),
                                ESP_EXT1_WAKEUP_ANY_LOW);
// Optional safety net: also wake once a week to check battery + report
esp_sleep_enable_timer_wakeup(7ULL * 24 * 3600 * 1000000);
esp_deep_sleep_start();
```

The weekly timer is debatable. Pure storage = no timer wake-ups. A weekly
"is the cell still alive?" check is < 1 µA average and gives you a
last-known battery voltage in the Home app. Make it Kconfig-tunable.

---

## Wake sources

| Source | Wire | Why |
|--------|------|-----|
| **Boot / user button** | EVK BOOT button or a dedicated front-panel button | Standard "wake me up" UX. |
| **Reed switch (magnet)** | One GPIO + a 5–10 MΩ pull-up, switch to GND | **Killer feature for AkvaLink.** Zero standby current (no closed circuit until magnet is present). Works through plastic and water. Perfect for waterproof enclosures with no exposed buttons. |
| Timer (optional weekly) | RTC | Battery health check / "I'm alive" Matter heartbeat. |

The reed switch is the AkvaLink-specific bit. For a poolside device the
enclosure is sealed — no buttons, no LEDs poking out, no holes for water
to find. A magnet on a keyring, brought close to the labelled spot, is
the entire UX. Cheap (~$0.20 for a normally-open reed), waterproof-friendly,
and looks magical to a non-technical user.

---

## The hidden battery killers

Even with the C6 in deep sleep at < 5 µA, these can blow the budget:

| Killer | Typical leak | Mitigation |
|--------|--------------|------------|
| **DS18B20 always powered** | ~750 µA active, ~1 µA standby — but on the EVK 3V3 rail it's never cut | Power sensor from a GPIO (or P-MOSFET for higher current). Drive low in storage mode. |
| **1-Wire pull-up to VCC** | 4.7 kΩ to 3.3 V → 700 µA if DQ is held low somehow | When sensor power is off, drive DQ as a GPIO output low — no current path. Or pull-up to the *switched* sensor VCC, not the always-on rail. |
| **E-ink driver IC standby** | ~5 µA per panel | Cut panel VCC via P-MOSFET (already in the e-ink plan). |
| **LDO quiescent current** | 50–500 µA on cheap LDOs | Use a low-Iq LDO (e.g. TI TPS7A02, < 1 µA Iq) — or run directly from 2× lithium AA / AAA (3.0–3.4 V) and skip the LDO entirely. |
| **USB-UART bridge on the EVK** | 5–20 mA when EVK is plugged into USB | Not relevant in storage mode (device runs on battery, USB unplugged). Worth flagging in production hardware design. |
| **Pull-ups on unused I²C lines** | 4.7 kΩ × 2 → 1.4 mA if held low | Disable internal pull-ups, ensure external pull-ups are on the switched bus rail. |
| **Stray GPIO inputs floating** | Unpredictable | Configure all unused GPIOs as input, no pull, *or* output low. ESP-IDF: `gpio_sleep_set_pull_mode` / `rtc_gpio_isolate`. |

**Verification recipe:** PPK2 in source-meter mode, 3.3 V, the device in
storage mode, lid closed, no USB. Anything > 20 µA average means one of
the killers above is still active. Bisect by re-enabling subsystems one
at a time.

---

## Battery chemistry — alkaline is the wrong choice

Pool / outdoor use means cold storage at some point. Alkaline cells:

- **Lose 30–50 % capacity below 0 °C.**
- **Leak over multi-month storage**, especially if partially discharged.
  Leaked alkaline kills the device. Permanently.
- High self-discharge over years.

**Use lithium primary cells.** Energizer Ultimate Lithium (L91 / L92) for
AA / AAA form factor:

- Operating range −40 °C to +60 °C with little capacity loss.
- 20-year shelf life.
- Don't leak.
- Higher initial voltage (1.8 V fresh) — make sure the regulator / direct
  drive copes (2× L92 = up to 3.6 V at start; well within ESP32-C6's
  absolute max).

Spec lithium AA/AAA on the BOM. Mention it explicitly in the user docs
("Use lithium cells. Alkaline will leak in winter and brick your sensor.").

For the integrated 18650 variant, choose a low-self-discharge cell
(Panasonic NCR18650B has ~2 %/month at room temp; cold storage helps).

---

## Wake-up flow (must feel instant)

The user-visible wake sequence:

1. Magnet near reed switch (or button press) → ext1 wake.
2. Quick boot → check wake reason → if storage-wake, skip the long
   commissioning splash.
3. **Power up DS18B20 → 100 ms settle → single fast read.** Show "29.4 °C"
   on the e-ink within 2 seconds. *This is the moment the user judges the
   product.*
4. Re-enable Thread (or Wi-Fi). NVS still has the fabric / Thread network
   key — `chip-tool` calls this "fast rejoin"; on Thread it's the
   "attaching to existing network" path, typically < 5 s.
5. Push the first temperature report.
6. Resume normal adaptive sampling.

Critical pieces for fast rejoin:

- **NVS partition is preserved** across deep sleep + storage mode (it's
  flash; nothing erases it). Verify our partition layout doesn't put
  anything destructive on wake.
- **Thread network key + Active Operational Dataset** are in NVS via
  esp-matter. Don't manually nuke them. (We currently do `nvs_flash_erase`
  on `NO_FREE_PAGES` — make sure that path is impossible in storage wake.)
- **Don't wait for full Matter commissioning UI** — that's only for first
  boot. On storage wake we skip straight to "join existing fabric".

---

## Marketing hook

This earns a real bullet on the box:

> **AkvaLink — drop it in the pool and forget it.
> Magnet wake. Lithium-ready. Survives a Swedish winter.**

Pair it with a video: device in a drawer for 3 months, magnet swipe,
temperature on screen in 2 seconds, Matter notification on the phone in 5.
That's the demo.

---

## Implementation sketch

Add to `app_main.cpp`:

```c
typedef enum {
    AKVALINK_NORMAL,
    AKVALINK_STORAGE,
} akvalink_mode_t;

void akvalink_enter_storage_mode(void);
```

New file `main/storage_mode.cpp` owns:
- The mode-entry sequence (radio teardown, sensor power off, splash).
- The wake-reason check at boot (`esp_sleep_get_wakeup_cause`).
- The fast-rejoin path.

Kconfig:
- `CONFIG_AKVALINK_REED_GPIO` — reed switch GPIO (default: TBD per schematic).
- `CONFIG_AKVALINK_STORAGE_BUTTON_HOLD_MS` — long-press threshold (default 5000).
- `CONFIG_AKVALINK_STORAGE_HEARTBEAT_DAYS` — 0 = no timer wake (default 7).

Tracked in [TODO.md](../TODO.md) under **Winter Storage Mode** (P0).
