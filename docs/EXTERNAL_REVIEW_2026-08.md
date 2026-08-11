# External review — August 2026

> Received 2026-08-11 from an experienced external reviewer. Kept here nearly
> in full because it is the best outside critique the project has had.
> **The theme: replace breadth with evidence.** Items are annotated with
> status where AkvaLink has already acted. The distilled priorities live in
> [../TODO.md](../TODO.md); the standing rules extracted from this review
> live in [../.github/copilot-instructions.md](../.github/copilot-instructions.md).

## Executive assessment

Strong: privacy-first local-only value proposition; simple cheap sensor +
single wireless SoC; unusual transparency about limitations and modeled
numbers; good developer experience (scripts, CI, releases, variants, app);
polished website.

**Biggest weakness:** the public-facing project mixes five maturity levels
without separating them: (1) works on EVK, (2) implemented but not
validated, (3) modeled only, (4) planned, (5) what a future finished device
might do. Separating those aggressively improves credibility and keeps the
project manageable.

## Highest-priority improvements

### 1. Measure power before doing anything else ⬅ the big one

Published battery figures are modeled duty cycles; only light sleep + DFS
are enabled, DS18B20 stays powered, report-and-disconnect Wi-Fi is not
implemented. Measure these states **separately**:

1. Cold boot
2. Matter commissioning
3. Thread attached + idle
4. Thread polling event
5. DS18B20 conversion
6. Matter attribute report
7. BLE advertising (if active)
8. Failed network attachment / border-router loss
9. Reconnection after an outage
10. Long-term steady state ≥ 12–24 h

Capture: average current, min sleep current, TX peak, duration + frequency
of each event, energy per sample / per report / per day, current during
failure and recovery. **Failure states matter more than they appear** — a
device that averages tens of µA normally but keeps searching for a missing
Thread network all winter can drain its battery surprisingly fast.

### 2. Publish measured and modeled values separately

Suggested public presentation:

- **Measured on EVK:** pending
- **Modeled custom PCB:** X years
- **Expected practical lifetime:** Y–Z years
- **Battery shelf-life limitation:** ~N years
- **Test assumptions:** temperature, threshold, poll interval, changes/day

Suggested wording: *"Target battery life: multiple years. The current
electrical model predicts up to ~12 years from 2× AA under ideal Thread
conditions. In practice, self-discharge, temperature, network conditions
and component leakage are expected to limit useful life to ~5–7 years.
Hardware measurement is still pending."* Never publish "12 years" without
the qualifier immediately alongside.

### 3. Reduce the visible scope — MVP definition

> **Battery-powered waterproof temperature sensor using Matter over Thread.**

- **Core:** NORA-W40, DS18B20, Matter over Thread, standard temperature
  cluster, battery %, re-provisioning, reliable low-power behaviour.
- **Alternative builds:** BLE-only, Wi-Fi station/AP, ESPHome.
- **Experimental:** ESP-NOW, Wi-Fi TWT, HTTP OTA, NORA-B2, e-ink.

Consider an `experimental/` marker in release filenames so experimentation
doesn't imply equal validation. *(AkvaLink decision: Thread Matter + BLE
are the product; everything else is a provided variant, not the headline.)*

### 4. Make maturity obvious on the landing page

"Available now" reads as "finished hardware you can obtain". Replace with
"Firmware available" / "Working prototype" / "EVK build available", and add
a status strip near the top: *"Project status: working EVK prototype.
Firmware and source available. Custom PCB, enclosure and measured battery
characterization in progress."*

## Hardware feedback

### 5. Design the custom PCB around measured leakage

The planned 390 kΩ + 100 kΩ battery divider draws ~6.7 µA at 3.3 V
permanently connected ≈ **59 mAh/year** — not negligible for a multi-year
sensor. Options: MOSFET-switched divider; drive divider top from a GPIO
only during measurement; higher resistance (respect ADC source-impedance);
cap at ADC input + settling time. Alkaline % is inherently imprecise
(temperature, load, chemistry, recovery) — consider broad states
**Good / Replace soon / Critical** instead of a precise percentage.

### 6. Switch sensor power (custom PCB)

Power the probe from a load switch / controlled rail; switch the 1-Wire
pull-up with the same rail; ensure DQ can't back-power the sensor; safe
GPIO state before power removal; configurable power-up + conversion delays.

### 7. External-probe protection

A long outdoor/pool cable is an electrical interface: ESD at connector,
series R on DQ, surge/transient protection, reverse-insertion tolerance,
connector water ingress, shield termination, ground-potential differences,
lightning-induced transients. A small TVS + sensible series impedance is
enough for a hobby device.

### 8. Treat the probe as a replaceable consumable

Cable entry, potting, strain relief and capillary ingress dominate field
reliability — not the stainless sheath. Replaceable probe connector outside
the sealed compartment; publish tested probe models; accelerated soak tests
in chlorinated + salt-chlorinated water; compare 2–3 suppliers; log drift
vs a reference thermometer.

### 9. RF architecture is part of the enclosure design

Electronics + antenna above the waterline, antenna at the top, battery
below it, separation between antenna and wet cable, external-antenna
variant for the first custom design, range testing with the enclosure
floating in its real position. Bench range results won't predict
performance near a water surface.

## Firmware improvements

### 10. Keepalive strategy — ✅ largely shipped

Two independent rules: report on threshold crossing AND at a max-silence
interval; immediate report on alert crossing; separate slower battery
report. *(Status: `CONFIG_AKVALINK_MATTER_KEEPALIVE_MIN` shipped, default
240 min. Reviewer suggests 30–60 min; revisit after power measurement.)*

### 11. Make adaptive sampling stateful and observable

Formalize as a state machine — Stable / Changing / Alert / Network
recovery / Low battery / Storage — and expose the current state in debug
output and BLE diagnostics. Makes power traces interpretable.

### 12. Design explicitly for network failure

Bounded recovery: exponential backoff, capped immediate retries, reduced
scanning after prolonged failure, persistent failed-attach counter,
low-power orphaned mode, button-triggered fast recovery, clear distinction
between "not commissioned" and "commissioned but network unavailable".
**Deserves its own power test — it may set the real worst-case battery life.**

### 13. Versioned configuration storage

NVS config struct with schema version, defaults, migration function,
CRC/validity marker, factory-reset policy, separate network vs application
reset. Reduces compatibility problems as OTA and settings evolve.

## Testing and repository quality

### 14. Firmware tests at the logic boundary

Don't unit-test ESP-IDF/Matter — extract our own deterministic logic into
platform-neutral C/C++ modules and run them in host CI: threshold +
hysteresis, adaptive-sampling transitions, keepalive timing, temperature
validation, DS18B20 error handling, alert crossings, battery mapping,
config migration, sensor-disconnected behaviour, extreme values, history
rollover.

### 15. Minimal hardware-in-the-loop smoke test

One EVK permanently on a test machine: programmable power switch, serial
log capture, known sensor (or emulator), build-flash-boot verification,
BLE advertisement discovery, temperature sanity check, factory-reset test.
Even a manually triggered nightly run catches what host tests can't.

### 16. Test each released variant, or release fewer

A release matrix per variant: Built in CI / Boot-tested / Hardware-tested /
Connectivity-tested / OTA-tested / Power-measured. Don't mark a variant
"supported" merely because it compiles.

## Website and documentation

### 17. Simplify the opening page

It currently serves three audiences at once (buyer, maker, embedded dev).
Top-level: what it is, project status, why local-only, one photo of the
real prototype, what works, build guide link. Deep-dive detail moves to
separate technical pages.

### 18. A real prototype photograph above conceptual diagrams

Answers instantly: does it exist, how is the probe connected, what hardware
do I need. Builds more confidence than more feature text.

### 19. Clarify the user journey — decision tree

- Apple/Google Home with Thread → **Matter/Thread (Recommended)**
- Home Assistant → ESPHome or Matter/Thread
- Just view on phone → BLE
- Browser bench demo → SoftAP
- Developing firmware → build guide

Mark exactly one binary **Recommended**.

### 20. Align status language everywhere

One vocabulary: **Implemented / Hardware-verified / Measured /
Experimental / Planned.** A feature matrix with those five labels beats a
general checklist.

## Suggested development order

1. Measure the existing Thread EVK power profile
2. Implement and validate keepalive reporting *(shipped — validate)*
3. Measure failure behaviour with Thread network unavailable
4. Switch off the DS18B20 between readings
5. Create a minimal custom PCB
6. Measure the custom PCB
7. Build the first real enclosure
8. RF + waterproof installation tests
9. Weeks of unattended operational data
10. Only then revisit additional connectivity variants

## Bottom line

Fewer primary variants, measured power, tested failure states, one custom
PCB, one credible enclosure, clear maturity labels, consistent battery
claims. **The best next deliverable is a 24-hour current trace from real
hardware — not another protocol or frontend.**
