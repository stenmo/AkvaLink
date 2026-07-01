# E-ink Display — Plan & Suggestions

> *"Most pool thermometers suck visually. Make yours: big clean number,
> battery icon, trend arrow. Update only when needed."*

E-ink is the natural fit for AquaLink: **zero current to hold the image**,
~30 mA only during the ~2-second refresh. Perfectly aligned with the
threshold-gated reporting model — display refreshes only when something
worth saying actually changed.

---

## 1 · Panel shortlist

All candidates are **SPI**, **monochrome** (or 3-colour), **driver IC
SSD1680 / IL0373 / UC8151** — all well supported by `GxEPD2` and by
direct register-level drivers.

| Panel | Resolution | Size | Price | Best for | Why / Why not |
|-------|-----------|------|-------|----------|---------------|
| **Waveshare 2.9" V2** | 296×128 | 66×29 mm | ~$15 | All-in-one battery enclosure, on-the-pool-edge unit | Sweet spot for size/cost. Big enough for a 60 px digit + battery + trend. Partial refresh supported. |
| **Waveshare 4.2" V2** | 400×300 | 84×64 mm | ~$30 | Wall-mounted "AquaLink dashboard" near the door | **Recommended for the demo.** Readable from 3-4 m. Massive digit area. Still <100 mA peak. |
| Waveshare 2.13" V3 | 250×122 | 48×27 mm | ~$11 | Tiny low-cost unit | Cheapest. Tight for big-digit + icons. |
| GoodDisplay GDEY029T94 | 296×128 | bare panel | ~$8 | Custom PCB integration | Same as Waveshare 2.9" but bare panel — for the productised version. |
| LilyGO T5 4.2" | 400×300 + ESP32 | dev board | ~$40 | Quick prototype, NOT for AquaLink | Has its own ESP32 — duplicates the NORA-W40. Skip. |

**Recommendation for v1:** Start with **Waveshare 4.2" V2 SPI**. Wall-mount,
huge legibility, only ~$30. Drop to 2.9" for the integrated battery-pack
version later.

## 2 · Wiring — NORA-W40 EVK (MikroBUS 2)

EVK MikroBUS 2 is free when the optional DS2482 click is on bus 1. Use
its SPI lines + a few extra GPIOs for DC/RST/BUSY.

| E-ink pin | Function | NORA-W40 GPIO (EVK MikroBUS 2) | Notes |
|-----------|----------|--------------------------------|-------|
| VCC       | 3.3 V    | 3V3                            | Panel + driver IC |
| GND       | GND      | GND                            | |
| DIN       | SPI MOSI | GPIO19 (MB2 SDI)               | |
| CLK       | SPI SCK  | GPIO18 (MB2 SCK)               | |
| CS        | SPI CS   | GPIO16 (MB2 CS)                | Active low |
| DC        | Data/Cmd | GPIO20 (MB2 PWM)               | High = data, low = command |
| RST       | Reset    | GPIO21 (MB2 RST)               | Active low |
| BUSY      | Busy     | GPIO22 (MB2 INT)               | High while panel is refreshing |

> Verify pins against the actual EVK-NORA-W40 schematic before committing —
> per repo rules, no pin claim ships without a verified source. Numbers
> above are placeholders to start a discussion, not gospel.

**Power switch trick:** drive panel VCC from a GPIO via a small P-MOSFET
(or directly from a GPIO if total current < 15 mA, which is true for the
2.9"). Cuts the ~5 µA driver-IC standby leakage between refreshes. Over a
year, that's a meaningful chunk of a 2× AA budget.

## 3 · Software stack

Two paths, in order of preference for this codebase:

### A. Native ESP-IDF SPI driver (recommended)

- ~400 lines in `main/eink_display.{cpp,h}`.
- Uses `spi_master` directly. No Arduino dependency, no extra component.
- Init sequence + LUT tables come from the panel datasheet (Waveshare
  publishes reference C code — adapt their `EPD_2in9_V2.c` / `EPD_4in2.c`).
- Tiny font renderer: pre-rasterise the 10 digits + symbols at the chosen
  size into a static array. ~2 KB flash. No FreeType, no LVGL.

### B. `GxEPD2` via Arduino-as-component

- Battle-tested, supports every Waveshare panel.
- Pulls in the Arduino-as-component layer — adds ~100 KB flash and
  complicates the esp-matter build. **Avoid unless we hit a panel quirk
  we can't easily replicate.**

### C. Component registry (`esp_lcd_epaper`, etc.)

- ESP-IDF v5 has `esp_lcd` panel drivers but e-paper coverage is sparse.
- Worth re-checking when we pick the exact panel — could remove the need
  to write the driver at all.

## 4 · Layout sketch (4.2" / 400×300)

```
┌────────────────────────────────────────┐
│  AquaLink            🔋 87%   ⏱ 3 min  │  ← header band, 24 px
│                                        │
│                                        │
│        2 8 . 4                         │  ← big digits, ~140 px tall
│              °C   ↑                    │     unit + trend on the right
│                                        │
│                                        │
│  Pool · Last commissioned 12 days ago  │  ← footer, 18 px
└────────────────────────────────────────┘
```

For 2.9" / 296×128, drop the footer and shrink the digit field to 80 px:

```
┌──────────────────────────────────┐
│  28.4 °C  ↑           🔋 87%     │
│                                  │
│  Pool                3 min ago   │
└──────────────────────────────────┘
```

## 5 · Refresh policy

Reuse the existing threshold logic — don't invent a new one.

- **Trigger a refresh when, and only when**, the same condition fires
  that would push a Matter report (Δ ≥ threshold, OR keepalive interval
  elapsed, OR battery state crossed a 5 % boundary).
- **Rate-limit:** no two partial refreshes within 30 s (panel ghosting +
  driver IC heat).
- **Full refresh once per day** to clear residual ghosting (cost: ~3 s
  visible flicker, ~30 mA × 3 s = 25 mAs).
- **Splash on boot:** logo + commissioning QR until first sample lands,
  then the live layout.

## 6 · Power impact (back-of-envelope)

For the 2.9" panel, with 4 refreshes per day in stable pool conditions:

| Item | Energy per event | Events/day | Energy/day |
|------|-----------------|-----------|-----------|
| Partial refresh | 30 mA × 0.5 s × 3.3 V = 50 mJ | 4 | 200 mJ |
| Full refresh    | 30 mA × 3 s   × 3.3 V = 300 mJ | 1 | 300 mJ |
| Driver IC standby (no GPIO power switch) | 5 µA × 24 h × 3.3 V | — | 1.4 J |
| Driver IC standby (with GPIO power switch) | ~0 µA | — | ~0 |

**Verdict:** without the power switch, the driver IC standby dominates
and roughly halves your battery life. **With** the power switch, e-ink
is essentially free.

## 7 · Open questions

- Outdoor visibility: can a 2.9" panel be read from poolside in direct
  sun through a clear acrylic window? (E-ink is reflective so it actually
  *gains* contrast in sunlight — but condensation inside the window is
  the real enemy. Need a desiccant pack or a vented enclosure.)
- Cold-weather refresh: e-ink is rated to 0 °C operating, ghosts badly
  below that. For freezer / cold-storage use, we may need to disable
  the display below 0 °C and rely on Matter only.
- Should the display side and the sensor side be **physically separate**
  (sensor in a tiny waterproof pod by the water, display indoors via
  Matter)? That collapses to "two AquaLinks", which is also a fine answer.
