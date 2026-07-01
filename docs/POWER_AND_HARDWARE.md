# NORA-W40 Matter Thermometer (DS18B20 / DS1822, single-SoC, Thread SED)

Matter **Temperature Sensor** end-node running directly on the ESP32-C6 inside
the u-blox NORA-W40 module — no host MCU, no ucxclient AT bridge.
Designed for **battery-powered** operation as a Thread Sleepy End Device (SED).

```
┌─────────────────────────────────────────────────────────────┐
│              EVK-NORA-W40  (ESP32-C6 single-SoC)            │
│                                                             │
│   esp-matter (Thread SED + BLE 5.3 commissioning)           │
│      └─ Matter Endpoint 1: TemperatureMeasurement           │
│             ├─ DS18B20 via direct GPIO15 (RMT bit-bang)     │
│             └─ DS18B20/DS1822 via DS2482-800 Click board    │
└─────────────────────────────────────────────────────────────┘
```

See [README_NORA_W40_THERMOMETER.md](../../README_NORA_W40_THERMOMETER.md)
at the repo root for hardware wiring, commissioning, and full usage.

## Quick reference

| Item | Value |
|---|---|
| Module | NORA-W401 / NORA-W406 (ESP32-C6, RISC-V @ 160 MHz) |
| Sensor | DS18B20 or DS1822 (1-Wire, ±0.5 °C; **12-bit / 0.0625 °C** on both the direct-GPIO and DS2482 paths — power is managed via adaptive modes + report threshold, not by coarsening resolution) |
| Sensor variants | DS18B20 (0x28), DS1822 (0x22), MAX31820 (0x3B) |
| **Direct GPIO** | EVK J15.4 = GPIO15, 4.7 kΩ pull-up to +3V3 |
| **DS2482 Click board** | MikroE I2C 1-Wire Click on MikroBUS 1 (SDA=GPIO6, SCL=GPIO7) |
| DS2482 I2C address | 0x18 (default, all ADR jumpers to GND) |
| DS2482 1-Wire channel | OW_IO0 (HD1 pin 1) — connect DS18B20 DQ here |
| Matter device type | Temperature Sensor (0x0302) |
| Endpoints | EP0 root, EP1 temperature sensor |
| Network | Matter-over-Thread (802.15.4), Sleepy End Device |
| Commissioning | BLE 5.3 (off after pairing to save power) |
| Framework | esp-matter release/v1.5 (connectedhomeip, ESP-IDF v5.4.1) |

## Sensor wiring

### Option A: Direct GPIO (default build)

```
DS18B20          EVK-NORA-W40
───────          ────────────
VDD (pin 3) ──── J16.26 (+3V3)
DQ  (pin 2) ──── J15.4  (GPIO15) ← 4.7 kΩ pull-up to +3V3
GND (pin 1) ──── J16.28 (GND)
```

### Option B: DS2482-800 Click board (`--clickboard` build)

Plug the MikroE "I2C 1-Wire Click" into MikroBUS 1, then connect a DS18B20
to the OW_IO0 header pin (HD1 pin 1):

```
DS18B20             Click Board HD1
───────             ───────────────
VDD (pin 3) ──── VCC (top of HD1)
DQ  (pin 2) ──── OW_IO0 (pin 1)
GND (pin 1) ──── GND (pin 10)
```

No external pull-up needed — DS2482 Active Pullup (APU) is enabled in firmware.

At init, the driver logs the full sensor identity:
```
I (1416) ds2482: 1-Wire ROM: 28-0417C4A2D3FF-2A (DS18B20)
I (1420) ds2482: Power supply: external VDD
I (1425) ds2482: Resolution: 12-bit (0.0625 °C/LSB, 750 ms conversion)
I (1430) ds2482: DS2482-800 OK on I2C 0x18, DS18B20 on OW_IO0
```

## Adaptive sampling

The sensor uses **adaptive sampling** for responsive UX with minimal battery drain:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| Fast period | 3 s | Used when temperature is changing rapidly |
| Slow period | 60 s | Used when temperature is stable |
| Fast threshold | 0.5 °C | Delta per read that triggers fast mode |
| Stable count | 5 | Consecutive stable reads before slowing down |
| Report threshold | 0.25 °C | Minimum change before pushing to Matter (4× the 12-bit 0.0625 °C LSB) |

All parameters are compile-time configurable in `app_priv.h`. For very stable
environments (pool, wine cellar, server room), increase thresholds to cut
reports and extend battery life dramatically:

| Profile | Report threshold | Fast threshold | Slow period | Use case |
|---------|-----------------|----------------|-------------|----------|
| Default | 0.25 °C | 0.5 °C | 60 s | Indoor room |
| **Pool** | **0.25 °C** | **0.5 °C** | **120 s** | Pool / spa / aquarium |
| Cold storage | 0.5 °C | 1.0 °C | 300 s | Freezer, wine cellar |

**Why 12-bit (0.0625 °C) resolution?** The DS18B20's *absolute accuracy is
±0.5 °C regardless of resolution* — more bits give finer steps, not a more
correct reading. We run the full 12-bit (0.0625 °C) so Home apps show the
finest reading the sensor can give (the ±0.5 °C accuracy caveat still applies).
The cost is a longer conversion (~750 ms vs ~187.5 ms at 10-bit), i.e. more
awake time per read — **power is managed by the adaptive modes and the report
threshold, not by coarsening the reading.** The report threshold (0.25 °C = 4×
the 0.0625 °C LSB) gates how often we push to Matter; the fast/slow sampling
periods gate how often we read. Both are the levers to tune against a real
Nordic PPK2 power measurement.

**Example — hot coffee to cold water:**
```
t=0s   85°C → FAST mode (Δ > 0.5°C)
t=3s   72°C → push to Matter
t=6s   58°C → push
t=9s   42°C → push
t=12s  28°C → push
t=15s  18°C → push, Δ < 0.5°C → settling...
t=27s  10.5°C → 5 stable reads → SLOW mode (60s)
```

Total time: **~15s of live updates**, then energy-saving 60s idle.

### Pool temperature scenario 🏊

A heated pool in Sweden at 28–29 °C is one of the **most battery-friendly**
scenarios: temperature barely changes, so reports are extremely rare.

**Typical pool day (summer, heated, 0.25 °C report threshold):**
```
06:00  28.25°C → heater on, stable                     (no report)
08:00  28.50°C → Δ=0.25°C → report                      (1)
12:00  28.75°C → Δ=0.25°C, solar gain                    (2)
16:00  28.75°C → stable                                 (no report)
20:00  28.50°C → Δ=0.25°C, cooling begins                (3)
00:00  28.25°C → Δ=0.25°C, night cooling                 (4)
04:00  28.00°C → Δ=0.25°C                                (5)
06:00  27.75°C → Δ=0.25°C, heater kicks in               (6)
```

**~6 reports/day** in summer. Even fewer on overcast days or with pool cover.

**Swedish winter** (pool covered/off, water near ambient):
```
Slow drift ~0.5°C/day → ~2–3 reports/day
```

**Battery calculation (Wi-Fi disconnect, 0.25 °C threshold):**

| Season | Reports/day | Reports/hour | Energy/day |
|--------|------------|-------------|------------|
| Summer (heated) | ~6 | 0.25 | 6 × 87 µAh + 20 µA × 24h = 1,002 µAh |
| Spring/autumn | ~4 | 0.17 | 4 × 87 µAh + 480 µAh = 828 µAh |
| Winter (covered) | ~2 | 0.08 | 2 × 87 µAh + 480 µAh = 654 µAh |
| **Year average** | **~4** | **0.17** | **~830 µAh/day = ~35 µA avg** |

| Battery | Capacity | Pool life (Wi-Fi disconnect) | Pool life (Thread SED) |
|---------|----------|------------------------------|------------------------|
| CR2477 | 1000 mAh | ~3.3 years | ~5 years |
| 2× AAA | 1200 mAh | ~4 years | ~6 years |
| **2× AA** | **2800 mAh** | **~9 years** | **~12+ years** |
| 18650 Li-ion | 3400 mAh | ~11 years | ~15+ years |

At **~35 µA average**, pool monitoring on 2× AA gives **~9 years Wi-Fi** or
**~12 years Thread** — the sensor outlives the batteries' shelf life.

> **Waterproofing note:** Use a DS18B20 in stainless steel probe housing
> (widely available on Amazon/AliExpress). Run the 3-wire cable to a dry
> enclosure with the NORA-W40 + battery. The DS2482 Click board works well
> here — longer cable runs (up to ~30 m) are more reliable over the I2C
> bridge than direct GPIO 1-Wire.

## Low power (Thread SED)

| Feature | Setting | Effect |
|---------|---------|--------|
| Thread SED poll period | 120 s | Radio wakes only 0.5×/min for incoming messages |
| Light sleep | Enabled | CPU + peripherals powered down between samples |
| DFS | 10 ↔ 160 MHz | CPU frequency scales with load |
| Peripheral power-down | Enabled | I2C, SPI, UART off during sleep |
| Flash power-down | Enabled | SPI flash off during sleep (~1 mA saving) |
| GPIO isolation | Enabled | Reduces pad leakage in sleep |
| BLE | Off after commissioning | Frees ~1 mA baseline |

## Estimated battery life

### Thread SED (default build)

Assumes: 60s idle sampling (adaptive), 120s SED poll, ~40 µA average current
at room temperature (stable). Fast sampling bursts add negligible average
current (< 1% of day is in fast mode for typical use).

| Battery | Type | Capacity | Estimated Life | Notes |
|---------|------|----------|---------------|-------|
| CR2032 | Coin cell | 220 mAh | ~7 months | ⚠️ Needs 100 µF buffer cap for TX bursts |
| **CR2477** | **Large coin** | **1000 mAh** | **~2.7 years** | **Viable with buffer cap** |
| 2× AAA | Alkaline | 1200 mAh | ~3.2 years | Good balance of size vs life |
| **2× AA** | **Alkaline** | **2800 mAh** | **7+ years** | **Recommended for wall-mount** |
| CR123A | Lithium | 1500 mAh | ~4 years | Good pulse current |

⚠️ **CR2032 alone won't work** — ESP32-C6 radio TX draws ~130 mA peaks,
but CR2032 max pulse is ~15 mA. Use CR2477+ or AA/AAA cells.

### Wi-Fi (`--wifi` build)

NORA-W40 supports **Wi-Fi 6 (802.11ax)** including **Target Wake Time (TWT)**,
which dramatically improves battery life over legacy Wi-Fi 4/5 devices.

Three power strategies, from simplest to most aggressive:

**Strategy A — DTIM-optimized (legacy, all APs)**

The device stays associated and wakes for DTIM beacons. Power depends on AP
DTIM setting and the device's **listen interval** (skip N beacons).

| AP DTIM | Listen interval | Wake period | Sleep current | Avg current |
|---------|-----------------|-------------|---------------|-------------|
| DTIM 1 | 1 (default) | ~102 ms | ~180 µA base | ~1.5 mA |
| DTIM 3 | 1 | ~307 ms | ~180 µA base | ~800 µA |
| DTIM 3 | 3 (skip 2) | ~922 ms | ~180 µA base | ~400 µA |
| **DTIM 10** | **1** | **~1024 ms** | **~180 µA base** | **~300 µA** |
| DTIM 10 | 3 (skip 2) | ~3072 ms | ~180 µA base | ~220 µA |

Light sleep base = 180 µA (u-blox datasheet). Higher DTIM = fewer wakeups.
Most consumer APs default to DTIM 1 or 3. Enterprise APs often support DTIM 10.

> **Tip:** Set `esp_wifi_set_ps(WIFI_PS_MAX_MODEM)` and configure listen
> interval via `wifi_sta_config_t.listen_interval` for optimal DTIM power.

**Strategy B — Wi-Fi 6 TWT (recommended, requires Wi-Fi 6 AP)**

TWT lets the device **negotiate** a wake schedule with the AP: "wake me every
N seconds for D milliseconds." Between TWT windows, the device sleeps deeply —
**no beacon listening at all**. The AP buffers frames and delivers them in the
agreed TWT window.

| TWT interval | Wake duration | Sleep current | Avg current | Notes |
|-------------|--------------|---------------|-------------|-------|
| 10 s | 10 ms | ~180 µA | ~190 µA | Responsive, moderate power |
| 30 s | 10 ms | ~180 µA | ~185 µA | Good balance |
| **60 s** | **10 ms** | **~180 µA** | **~182 µA** | **Match sample period** |
| 120 s | 10 ms | ~180 µA | ~181 µA | Very low power |

The key insight: with TWT, sleep current (~180 µA) dominates regardless of
interval — the wake duty cycle is negligible. TWT at 60s ≈ the slow sample
period, so reports piggyback on the scheduled wake.

**TWT advantages over DTIM:**
- ✅ Device stays **associated and reachable** at TWT wake times
- ✅ AP knows the schedule — no wasted beacon wakeups
- ✅ ~182 µA average vs ~300–800 µA for DTIM → **2–4× better**
- ✅ Matter subscriptions stay alive (controller sends at TWT window)
- ⚠️ Requires Wi-Fi 6 (802.11ax) AP with TWT support
- ⚠️ Not all consumer APs support TWT yet (most Wi-Fi 6E/7 routers do)

> **ESP-IDF TWT setup:** Use `esp_wifi_sta_itwt_setup()` — see Espressif's
> ITWT example project (referenced in EVK-NORA-W40 user guide).

**Strategy C — Disconnect between reports (best battery, any AP)**

Wi-Fi is **completely off** between reports. The device only reconnects when
it has something to send (temperature changed ≥ 0.25 °C), sends the update,
then disconnects. Sleep current drops to ~7 µA (deep sleep) or ~20 µA (light
sleep with RTC).

| Phase | Duration | Current | Energy per report |
|-------|----------|---------|-------------------|
| Wi-Fi scan + associate | ~1.5 s | ~100 mA | ~42 µAh |
| DHCP | ~0.5 s | ~100 mA | ~14 µAh |
| Matter session resume (CASE) | ~1 s | ~100 mA | ~28 µAh |
| Report TX | ~50 ms | ~180 mA | ~2.5 µAh |
| Disconnect | ~50 ms | ~50 mA | ~0.7 µAh |
| **Total per reconnect** | **~3 s** | | **~87 µAh** |

Average current depends on report frequency:

| Scenario | Reports/hour | Avg current | 2×AA life |
|----------|-------------|-------------|-----------|
| Kitchen (temp changing often) | 6 | ~0.5 mA | ~8 months |
| Living room (moderate changes) | 2 | ~0.19 mA | ~1.7 years |
| **Bedroom (very stable)** | **0.5** | **~0.06 mA** | **~5 years** |
| Outdoor (slow seasonal drift) | 0.2 | ~0.04 mA | ~8 years |

**Trade-offs:**
- ✅ Best battery life — approaches Thread SED in stable environments
- ✅ Works with any AP (no Wi-Fi 6 required)
- ⚠️ Device shows "offline" in controller between reports
- ⚠️ ~3 s reconnect latency when controller sends a command
- ⚠️ Matter subscriptions lapse; controller re-subscribes on reconnect

**Choosing a strategy:**

| Reports/hour | Best strategy | Why |
|-------------|---------------|-----|
| > 6 | TWT (60 s) or DTIM 10 | Reconnect overhead too high |
| 2–6 | TWT (60 s) | Stays reachable, low power |
| < 2 | Disconnect | Sleep current wins |
| Any (USB powered) | DTIM 3 | Simplest, always reachable |

**Battery life — all strategies (2× AA = 2800 mAh)**

| Strategy | Avg current | 2×AA life | Reachable? | AP requirement |
|----------|-------------|-----------|------------|----------------|
| DTIM 1 (default) | ~1.5 mA | ~3 months | Always | Any |
| DTIM 3 | ~800 µA | ~5 months | Always | Any |
| DTIM 10 | ~300 µA | ~13 months | Always | AP config |
| **TWT 60 s** | **~182 µA** | **~1.8 years** | At TWT window | **Wi-Fi 6 AP** |
| Disconnect (2/hr) | ~190 µA | ~1.7 years | No | Any |
| Disconnect (stable) | ~60 µA | ~5 years | No | Any |

### Thread vs Wi-Fi — power comparison

| | Thread SED | Wi-Fi + TWT | Wi-Fi (disconnect) | Wi-Fi (DTIM 3) |
|---|---|---|---|---|
| Sleep current | ~30 µA | ~180 µA | ~20 µA | ~180 µA + beacons |
| Average current | ~40 µA | ~182 µA | ~60–500 µA | ~800 µA |
| 2× AA battery life | **7+ years** | **~1.8 years** | **1.7–5 years** | ~5 months |
| Always reachable? | Via OTBR | At TWT window | No | Yes |
| Needs border router? | Yes (OTBR) | No | No | No |
| AP requirement | None | Wi-Fi 6 | Any | Any |
| Commissioning | BLE → Thread | BLE → Wi-Fi | BLE → Wi-Fi | BLE → Wi-Fi |

## Build / flash

```powershell
:: First time only — install ESP-IDF v5.4.1 + esp-matter v1.5 in WSL (~10 GB).
.\launch-aqualink-wsl.cmd setup

:: Build the firmware (≈ 5–10 min cold, < 1 min warm).
.\launch-aqualink-wsl.cmd build

:: Flash and watch the boot log.
.\launch-aqualink-wsl.cmd --flash COM5
.\launch-aqualink-wsl.cmd --log COM5
```

Linux / macOS — substitute `.sh` and `/dev/ttyUSB0`.

## File layout

```
opencpu/nora-w40-thermometer/
├── CMakeLists.txt              ← ESP-IDF project root
├── sdkconfig.defaults          ← Matter / Wi-Fi / BLE / partition defaults
├── partitions.csv              ← 4 MB layout with factory + OTA partitions
├── main/
│   ├── CMakeLists.txt
│   ├── idf_component.yml       ← pulls esp-matter, onewire_bus, ds18b20
│   ├── app_main.cpp            ← Matter init + sensor loop
│   ├── ds18b20_task.h / .cpp   ← 1-Wire sampling task → MeasuredValue
│   └── app_priv.h
├── build.cmd / build.sh        ← thin wrappers around idf.py
├── flash.cmd / flash.sh        ← idf.py flash (no esptool offset bookkeeping)
├── images/                     ← prebuilt .bin drop (gitignored except README)
└── README.md                   ← this file
```

## Why a separate IDF project?

See [`opencpu/README.md`](../README.md) — short version: this is a different
binary on a different chip with a different SDK. Mixing it into the host-side
`app/` build would be a category error.
