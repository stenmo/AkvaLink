# RF & Antenna Design — NORA-W40 in a Floating Enclosure

> *"On something floating in water like AkvaLink, RF design will make or
> break the user experience — especially for Thread/Matter stability."*

A floating, sealed, battery-powered Matter device in chlorinated water is
an unusually hostile RF environment. Most "works on the desk, fails in
the pool" stories come down to antenna placement that ignored the
waterline. This doc captures the rules we follow on the AkvaLink Smart
Float, sourced from ESP32-C6 and u-blox NORA-W40 best practice + the
specific physics of 2.4 GHz over water.

> **Verify against the live datasheet.** Before committing the PCB,
> cross-check every NORA-W40 keep-out value here against the current
> u-blox NORA-W40 hardware integration manual via the
> `mcp_u-blox-docs_search_u_blox_knowledge_sources` MCP server. Repo
> rules say no hardware claim ships unverified — the numbers below are
> a starting point for the layout discussion, not the layout itself.

---

## First principle

The antenna must "see air". Anything else attenuates, detunes, or both:

| Material near antenna | Effect at 2.4 GHz |
|-----------------------|-------------------|
| Water                 | Heavy absorption — kills 2.4 GHz badly |
| Battery (cell can)    | Detunes, blocks radiation |
| Copper / ground plane | Blocks (acts as reflector at best) |
| Wet plastic           | Attenuates if conductive residues form |
| Dry plastic (ABS/ASA/PC) | Acceptable, low loss — *the only allowed neighbour* |

**On a floating device, the antenna must be well above the waterline.**
Target: **≥ 20 mm of vertical air between the antenna feed and the
nominal waterline.** Less than that and Thread RSSI swings 10 dB+ as
the float rocks in chop.

---

## NORA-W40 keep-out rules

For NORA-W40 modules (NORA-W401 with U.FL, or NORA-W406 with PCB
antenna), the integration manual defines a strict no-metal / no-component
exclusion volume around the antenna feed. As a working baseline:

- **Length:** 15–20 mm extending out from the antenna feed point.
- **Width:** at least the full module width (~8–10 mm), preferably wider.
- **Height:** the **entire enclosure top section** above the antenna —
  no PCB, no battery, no shield, no screw, no metallised label.

Inside that volume:

- ❌ **No copper** (top, bottom, or inner layers).
- ❌ **No components** (passives, IC, screw, anything).
- ❌ **No battery** (especially the metal can — worst offender).
- ❌ **No metal label, paint with metal flake, or conductive coating.**
- ✅ **Plastic only** — ABS / ASA / PC. Thin-wall (1.5–2.0 mm) directly
  above the antenna — acts as the RF window.
- ✅ **Air gap preferred** — see "air dome" below.

This applies to both module variants. NORA-W401 (external antenna via
U.FL) gives the most placement flexibility, since the antenna can be
placed exactly where the enclosure has air; NORA-W406 (PCB antenna)
constrains you to the module's own pattern, so the *module* must be on
the top edge.

---

## Recommended placement on the Smart Float

Top view of the float, antenna at the upper rim:

```
   AkvaLink top housing (top view)
   ____________________________________
  /                                    \
 |        ┌──────────────────┐          |
 |        │  E-INK DISPLAY   │          |
 |        └──────────────────┘          |
 |                                  ANT |   ← module on edge,
 |   MCU + flash + DS2482-opt           |     antenna outward
  \____________________________________/
                  ^
                  └── all the metal lives on this side
```

Side view showing the air gap and waterline:

```
            TOP (above water, dry, plastic-only)
       ┌──────────────────────────────────┐
       │   E-INK DISPLAY                  │
       │                                  │
       │   NORA-W40    [ANTENNA → → → →   │   ← antenna at top rim,
       │                                  │     pointing outward / up
       └──────────────────────────────────┘
                 │  air-pocket / RF window (~5–10 mm)
                 │
       ───────────────────────────────  ← waterline
                 │ ≥ 20 mm vertical
                 │
                 │  stem (PETG / ASA, no metal)
                 ▼
            DS18B20 sensor (stainless tip)
```

### Module orientation & polarisation

- Antenna pointing **outward and slightly upward** (not down into the
  hull, not horizontal across the PCB).
- Roughly **horizontal polarisation** is fine for an indoor Thread BR /
  Wi-Fi AP at typical mounting height; what matters more is that the
  antenna isn't "looking" at the battery.

### Air dome (high-impact, low-cost)

A small dome / cavity in the top housing directly above the antenna
keeps the dielectric loading constant even when the outside is wet. If
the plastic above the antenna can pool a film of water against it,
detuning is unstable; an air dome decouples the antenna from anything
that touches the outer surface.

```
        ___                ___
       /   \  air dome    /   \
      / ___ \────────────/ ___ \
     | |ANT|                   |   ← thin-wall (1.5–2 mm)
      \_____\____________/_____/
```

---

## Battery placement

For 2× lithium AAA on the Smart Float:

- **Centre or far side** of the PCB — opposite the antenna.
- Or **stacked vertically under the PCB centre** with the antenna at the
  top rim above. Battery cans don't sit under the antenna, ever.
- Battery springs and contacts count as metal — keep them out of the
  keep-out volume too.

## Other things-not-to-cross-the-RF-zone

- **E-ink driver SPI lines** — radiate broadband when toggling. Route
  them on the inner layer, away from the antenna feed (~10 mm minimum).
- **DS2482 I²C lines** — same rule, less critical (slow signals).
- **Sensor power-switch FET** — the switching edges are slow but the
  trace can act as a parasitic radiator. Keep ≥ 10 mm.

## Minimum safe distances (working rules of thumb)

| Item | Distance from antenna feed |
|------|----------------------------|
| Battery / cell can | ≥ 15 mm |
| Ground plane edge | ≥ 10–15 mm |
| E-ink driver / SPI bus | ≥ 10 mm |
| Any screw / metal insert | ≥ 10 mm |
| Waterline (vertical) | ≥ 20 mm |

These are rules of thumb to **start** layout. The NORA-W40 hardware
integration manual is authoritative and may require larger keep-outs;
defer to it.

---

## Three-zone enclosure layout

Split the top housing into RF zones during ID + PCB layout:

```
    ┌────────────┬──────────────────────┬───────────┐
    │  Zone A    │       Zone B         │  Zone C   │
    │  ANTENNA   │  MCU + DISPLAY       │  POWER    │
    │            │                      │           │
    │ plastic    │ PCB ground plane     │ batteries │
    │ + air      │ allowed here         │ + LDO     │
    │ ONLY       │                      │           │
    └────────────┴──────────────────────┴───────────┘
       ≥ 20 mm        normal layout         well away
       to waterline   ground rules          from Zone A
```

Zone A is sacred — nothing crosses into it but air and the host plastic.

---

## Thread-specific notes

802.15.4 at 2.4 GHz is **more sensitive to detuning than Wi-Fi in
practice**: Wi-Fi recovers from a poor-link condition by re-associating
or stepping a rate down; Thread mesh stability depends on stable RSSI
to a parent router. A floating device that wobbles 8 dB every wave
cycle will quietly become an unreliable child even if it never fully
disconnects.

Mitigations baked into the Smart Float design:

- Antenna ≥ 20 mm above waterline (no submersion under chop).
- Air dome (constant dielectric).
- Self-righting ballast (no flips, no display-down + antenna-down failure).
- 60/40 buoyancy (no slow drift toward submersion as the cell ages).

---

## What "doing it wrong" looks like

Symptom checklist for a misplaced antenna on a floating device:

- ✅ Pairs fine on the bench. Loses parent within a minute when actually
  in the pool.
- ✅ RSSI varies > 10 dB between flat-water and small-chop conditions.
- ✅ Apple Home shows the device as "No response" intermittently.
- ✅ Range is great when held up out of the water, terrible at the
  designed waterline.
- ✅ A salt-pool variant fails where the chlorine-pool variant works.

If we're seeing any of those after the first prototypes, the fix is
almost always: move the module, raise the antenna, enlarge the keep-out
volume — not "tune the firmware".

---

## Open questions / next steps

- Run the **exact NORA-W40 keep-out values** through the u-blox docs MCP
  before drawing the PCB outline.
- Decide NORA-W401 vs. NORA-W406:
  - **W401 (external, U.FL):** cleanest answer for the Smart Float —
    place the antenna anywhere we want air, route a thin coax up.
    Adds BOM cost + a connector + an antenna part.
  - **W406 (PCB):** cheaper, fewer parts, but the *module* must sit at
    the top rim with the keep-out volume intact. Possible on a 90 mm
    body, just constraints the layout.
  - Working assumption: **NORA-W401 for v1** (gets us out of layout
    headaches), revisit W406 for the cost-down version.
- Worst-case pool RF model: 1 m horizontal distance to a ladder-mounted
  border router antenna, 2 m vertical drop, salt water. Quick link
  budget calculation before committing the antenna choice.
- Bench A/B test: same firmware, same room, antenna in air vs. antenna
  20 mm above a 30 cm × 30 cm tray of pool water. Measure RSSI delta
  to a fixed Thread BR. If the delta exceeds the link margin, raise
  the antenna further.

> *Tracked in [TODO.md](../TODO.md) under **Productisation** (P2).*
