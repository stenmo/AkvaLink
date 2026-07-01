# Enclosure & Industrial Design — Notes

> *"This is where AquaLink becomes something people actually want in their
> pool, not just tolerate."*

Three things have to happen together — get one wrong and the product
fails:

1. **Stable temperature reading** (good water contact, no sun-heated body).
2. **Good visibility** (e-ink readable from poolside, at an angle).
3. **Practical handling** (tie it down, store it, doesn't drift away).

Below: design directions, the recommendation, and the mechanical details
not to skip.

---

## Design directions

### 🌊 1. Smart Float — *recommended default*

A floating puck with a submerged probe tail.

- **Top:** flat or slightly domed, e-ink display centred.
- **Bottom:** weighted, with the DS18B20 probe sitting **10–20 cm below
  the surface** on a short stainless tail.
- **Tether eyelet** moulded into the rim.
- **Self-righting** by ballast — never flips display-down.

Why this wins:
- Accuracy: the probe is in the actual pool water, not in a sun-heated
  plastic shell on the surface (the mistake every cheap floating
  thermometer makes).
- Always readable, always upright.
- Survives being kicked, swum into, or sat on by a duck.

### 🧊 2. Ice-hockey-puck (minimalist / cheap version)

Low-profile sealed disc, semi-submerged.

- Pros: clean look, almost indestructible, cheapest to mould.
- Cons: display is flat → bad reading angle from poolside; sensor inside
  the body → solar heating bias unless carefully insulated and the
  probe sticks out.
- **Sensor must still be on a short tail** outside the body, even on the
  cheap version, or accuracy is junk.

### 🧪 3. Probe + buoy head (premium / pro)

Small floating head (display + electronics), cable down to a weighted
temperature probe.

- Pros: best accuracy, "instrument" feel, sensor depth is tunable.
- Cons: cable = failure point, harder to package, less "lifestyle".
- Slot this for a *pro / installer* SKU later, not the consumer hero.

### 😎 4. Pool-gadget (visually distinctive)

Slightly organic / soft-triangle shape, matte white top, black e-ink
window, subtle LED ring that lights only during pairing.

- Same Smart Float internals, different ID language.
- Where AquaLink can actually stand out on a shelf.

---

## Recommendation: **Smart Float**

Visual summary:

```
        ┌──────────────────────────┐         ← matte white / light grey
        │   ┌──────────────────┐   │         ← e-ink window (black bezel)
        │   │     2 8 . 4      │   │
        │   │       °C  ↑      │   │
        │   └──────────────────┘   │
        │            o             │         ← tether eyelet
        ╰──────╮            ╭──────╯
   ~~~~~~~~~~~~╲~~~~~~~~~~~╱~~~~~~~~~~~~     ← waterline
                ╲          ╱                  ← darker lower hull
                 ╲        ╱                     (hides dirt / algae)
                  ╲______╱
                     │
                     │  ← stainless tail (~10 cm)
                     │
                    [ ]  ← DS18B20 probe (weighted)
```

- Top: matte white / light grey (UV-stable ASA).
- Display: centred, black bezel for contrast, slight tilt for poolside readability.
- Bottom: darker grey (hides algae / waterline staining).
- Subtle embossed `AquaLink` logo on top — no paint, no print.

Working dimensions are in
[Concept V1 — dimensions and layout](#concept-v1--dimensions-and-layout) below.

### Buoyancy tuning (critical)

Aim for:

- **60–70 % above water** (display dry, readable, e-ink not condensation-fogged).
- **30–40 % below water** (stability, good thermal coupling on the lower
  hull, probe always submerged even with small waves).

If it sits too high: it'll roll in chop, the probe lifts out, readings
spike. Too low: water washes the display, ghosts the e-ink and looks bad.

### Display placement

- **Slight tilt, ~10–20°** off horizontal.
- Flat displays disappear when you read them from a pool lounger 1.5 m
  above the water surface — the angle matters more than the size.
- Even a domed top with the e-ink applied to the slope works.

---

## Concept V1 — dimensions and layout

Working target for the first foam-core / 3D-printed mockup. Numbers are
deliberately conservative; tune after the float test.

### Front view (top)

```
        ______________________
     .-'                      '-.
   .'                            '.
  /                                \
 |            ┌──────────┐          |
 |            │  24.6 °C │          |
 |            │   ☼      │          |
 |            └──────────┘          |
 |                                  |
 |          AquaLink                |
  \                                /
   '.                            .'
     '-.______________________.-'
              ⬤
           (tether loop)
```

### Side view (the part that matters)

```
            ┌───────────────┐
            │   E-INK       │
            │   DISPLAY     │
         ___└───────────────┘___
      .-'                       '-.
    .'                              '.
   /                                  \
  |                                    |
  |       ELECTRONICS + BATTERIES      |   ~25 mm
  |____________________________________|
              |             |
              |             |   ← stem (~6–8 mm Ø)
              |             |
              |             |
             /               \
            /                 \
           |   WEIGHTED TIP    |   ← DS18B20 inside
            \                 /
             \_______________/

   ~~~~~~~~~~~~~~~~~~~~~~~~~~~      ← waterline
                ↑ ~60 % above
                ↓ ~40 % below
```

### Dimensions (target)

| Part | Size |
|------|------|
| Total height (top of dome → tip) | ~140 mm |
| Floating body diameter | 90 mm |
| Top housing height | 25 mm |
| Display window | 42 × 30 mm |
| Stem length | 80–100 mm |
| Stem diameter | 6–8 mm |
| Sensor tip | ~20 mm |
| Submerged depth (water → tip) | ~50–70 mm |
| Tether loop hole | Ø 4–5 mm |

### Mass distribution

- **Top**: light — PCB, NORA-W40, 2× lithium AAA.
- **Stem**: structural only.
- **Tip**: weighted (stainless slug or epoxy + brass) — places the
  metacentre well below the floatation centre, so the device always
  self-rights.

### Internal stack-up (top section, top → bottom)

```
[ E-ink display              ]
[ PCB (NORA-W40 + DS2482-opt)]
[ Antenna keep-out zone  ⚠   ]   ← see RF doc
[ 2× lithium AAA             ]
```

Antenna sits at the **top edge** of the PCB, in a plastic-only air-pocket
above. Batteries on the **opposite** side from the antenna, never directly
behind it. Full keep-out rules in
[docs/RF_AND_ANTENNA.md](RF_AND_ANTENNA.md).

### Small but high-impact tweaks

- **Display tilt 10–15°** — readable from a poolside lounger.
- **Matte top finish** to kill glare on the e-ink window.
- **Soft silicone ring on the underside** of the float — quiets drift
  noise against ladder rungs and pool walls, and adds grip on the cover
  during storage.

### Why this works

- Accurate temp — sensor is well below the surface, on a thermal path
  isolated from the sun-heated body.
- Stable — 60/40 buoyancy with weighted tip → upright in chop.
- RF-friendly — antenna sits above the waterline in an air-only zone.
- Manufacturable — 2-part top housing + a stem moulding. O-rings between
  housings, stem-to-tip ultrasonically welded.
- Easy to seal to IP67 / IP68.

---

## Tether — keep it dumb

- One **moulded eyelet** in the rim, big enough for a finger.
- Ship with a short length of UV-stable nylon cord + a stainless clip.
- Optional silicone strap accessory for ladders / handrails.
- **Skip:** magnets (rust, leak paths), suction cups (fall off), QR straps.

Users will tie it to:
- Pool ladder rung
- Corner of the cover roller
- Skimmer basket handle
- A discreet eye-bolt in the deck

---

## Mechanical details — don't skip these

| Detail | Why |
|--------|-----|
| **Double O-ring seal** at the battery hatch | One ring is hope, two is engineering. IP67 minimum, IP68 if we can. |
| **UV-resistant plastic** (ASA or UV-stable ABS) | Pool water + sun = standard ABS yellows and embrittles in one summer. |
| **Anti-slip texture** on the top rim | Wet hands, retrieving from water. |
| **No sharp edges, no pinch points** | Kids and pool safety regs (CPSIA in the US, EN 71 in EU). |
| **Battery hatch accessible without tools** | Quarter-turn bayonet with O-rings, not screws. |
| **Stainless probe tail** (not bare wire) | Chlorine eats copper. |
| **Strain relief** where the tail meets the body | Where every cheap probe eventually fails. |
| **Hidden reset pinhole** | Paperclip-only, sealed by a tiny silicone plug. |
| **Subtle "tap area" indicator** on the top | Even if v1 has no touch, leaves room for a future capacitive wake. |
| **Drainage groove** under the battery hatch | If a drop sneaks past the seal, it has somewhere to go that isn't the PCB. |

---

## Anti-patterns to avoid

- **Sensor inside the body, no tail.** Solar heating gives 3–5 °C error
  in summer. This is the single most common failure of consumer pool
  thermometers — don't repeat it.
- **Display flat on top.** Unreadable from anywhere except directly above.
- **Glued shell, no battery access.** Two seasons and the customer throws
  it away. Bad for the planet, bad for the brand.
- **Standard ABS or PETG.** UV-yellowed in one summer.
- **Glossy finish.** Looks great on the shelf, looks terrible after one
  week of pool chemicals.
- **Paint or printed logo.** Wears off. Use embossing / in-mould labels.

---

## Open mechanical questions

- **Antenna placement.** Floating in conductive (chlorinated, salt) water
  is hostile to RF. NORA-W401 (external antenna) routed into the upper,
  always-dry half of the body. Verify range to a typical Thread Border
  Router on the inside of a house wall — likely needs a small ground
  plane in the lid. *Need to check NORA-W40 antenna keep-out via the
  u-blox docs MCP server before drawing the PCB.*
  Full rules and a Smart-Float-specific placement diagram in
  [docs/RF_AND_ANTENNA.md](RF_AND_ANTENNA.md).
- **Reed switch location** (see [WINTER_STORAGE_MODE.md](WINTER_STORAGE_MODE.md)) —
  put it in the upper rim with a small embossed magnet target on the
  outside. Works through plastic, no holes.
- **Heat path from sensor body to water** — the lower hull conducts; if
  we want even faster response we can co-mould a small thermally-
  conductive insert near the probe seat.
- **Salt-pool chemistry.** Salt chlorinators run at ~3000 ppm NaCl —
  much harsher on stainless than fresh-chlorine pools. 316L probe, not
  304.

---

## Positioning

Not "another cheap pool thermometer". The pitch is:

> *A smart, long-life, always-visible pool sensor.*

That positioning earns the lithium cells, the e-ink display, the moulded
eyelet, the double O-ring, and the matte ASA shell. None of those cost
more than a couple of dollars at scale, but together they're the
difference between "junk drawer in October" and "still on the pool
ladder in 2030".

---

## Next steps (if/when we move past the EVK)

1. Foam-core mockup at the recommended dimensions — verify it floats
   the right way up with a roughly EVK-equivalent ballast inside.
2. 3D-printed shell (PETG for prototyping speed; ASA for the real one).
3. PCB outline drawn to match the enclosure, **not** the other way around.
4. Drop test, tether test, 30-day chlorine soak, UV cabinet (or just
   leave it on a sunny windowsill for a summer).
5. Pick a real ID partner if we want the visually-distinctive
   "pool gadget" version. The mechanical engineering is in-house;
   the styling probably isn't.

> *Tracked in [TODO.md](../TODO.md) under **Productisation** (P2).*
