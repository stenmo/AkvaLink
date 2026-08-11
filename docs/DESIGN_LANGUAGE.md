# AkvaLink — Design Language

Visual and industrial design reference for AkvaLink hardware, firmware UI and web.

Status: proposal / working draft. Suggested location in repo: `docs/DESIGN_LANGUAGE.md`.

---

## 1. Reference point

The design language sits at one specific intersection: **Dieter Rams at Braun, 1955–1975**.

This is deliberate rather than decorative. "Retro 50s–70s", "Apple" and "minimal but
functional" are not three separate directions — Apple's visual grammar came directly out
of Braun's, so picking Rams collapses all three into a single, internally consistent
reference that can be checked against.

Useful specific objects to look at:

| Object | Year | What to take from it |
|--------|------|----------------------|
| Braun T3 pocket radio | 1958 | Squarish body, generous radius, one control |
| Braun TP 1 / TP 2 | 1959–60 | Bone white + charcoal, disciplined grid |
| Braun RT 20 table radio | 1961 | Type as the only ornament |
| Braun ET 66 calculator | 1987 | Numerals as the hero; functional colour coding |
| Braun ABW 30 wall clock | 1982 | Neutral face, one accent element |
| Apple iPod (1st gen) | 2001 | The same radius/negative-space logic, 40 years later |

### Rams' principles that actually bind decisions here

- **As little design as possible.** If an element does not survive the question "what
  breaks if this is removed?", remove it.
- **Honest.** Do not imply capability the device does not have. Applies directly to
  AkvaLink: no fake battery percentage while no sense divider is fitted, no "live" dot on
  a reading that is four hours old.
- **Understandable.** A person should read the display from three metres across a pool
  deck without instruction.
- **Long-lasting.** Avoid trend-coded styling (glassmorphism, gradients, neon). Bone
  white and charcoal will not date.

### A second reference point: retro Palm Springs style

Rams gives the object its discipline; **retro Palm Springs style — the mid-century
desert-modern look of roughly 1946–1970** — gives it a climate, a pool, and some warmth.
It's the one retro aesthetic built entirely around exactly AkvaLink's situation: strong
sun, a swimming pool, and enough restraint to build lightly around both instead of
over-decorating them.

| Landmark / artefact | Era | What to take from it |
|----------------------|-----|----------------------|
| Kaufmann Desert House | Richard Neutra, 1946 | Flat overhanging roof planes as sun-shade, not ornament |
| Twin Palms Estate (Sinatra) | E. Stewart Williams, 1947 | Low horizontal massing, glass meeting stone |
| Elrod House | John Lautner, 1968 | One dramatic structural gesture; everything else recedes |
| Alexander tract homes | Palmer & Krisel, 1957–1965 | Breeze-block screens: a functional vent that is also the only ornament |
| *Poolside Gossip* (photograph) | Slim Aarons, 1970 | The turquoise pool against bone stucco and grey stone — the palette, basically |
| Googie signage / travel posters | 1950s–60s | Jet-age optimism, palm-frond and sunburst motifs, playful lettering |

Two things carry directly into this document — and one thing stays firmly on the
marketing side of the line, not the device:

- **The palette was already right.** `signal` (`#C8462B`) reads as sun-baked
  terracotta/adobe against `bone`; the web's `link` cyan (`#0AA2C0`) is the same note
  as the Slim Aarons pool turquoise. Retro Palm Springs isn't a reason to add colours —
  it's the reason these two accents already work together, and a reason not to add a third.
- **Breeze block as an honest motif.** A perforated screen was never decorative in
  Palm Springs modernism — it was shade and airflow made visible. If the sensor float or
  display receiver ever need a vent (electronics cooling, humidity equalisation), a
  breeze-block-style perforation is the on-brand way to do it — function first, pattern
  second. Never add the pattern with no vent behind it.
- **The playful retro half (postcard colours, palm-frond icons, Googie script) is a
  marketing-and-photography mood, not a device rule.** It can live on the web page's
  hero, packaging or a launch photo; it must not creep onto the e-ink face or the
  enclosure silkscreen — that surface stays Rams-strict. One reference softens the
  other; neither should dilute it.

---

## 2. Colour

Two neutrals, one signal colour, one web-only link colour. That is the whole system.

| Token | Hex | Use |
|-------|-----|-----|
| `paper` | `#F8F6F0` | E-ink panel white; site background |
| `bone` | `#E9E5DA` | Enclosure shell; card surfaces |
| `ink` | `#1C1C1A` | All primary type, all glyphs, sparkline stroke |
| `grey` | `#8A8781` | Secondary labels, wordmark, muted metadata |
| `grey-dark` | `#77746C` | Label prefixes (`MIN`, `MAX`) where more weight is needed |
| `edge` | `#CBC5B5` | Hairline seams, bezel outline, table rules |
| `signal` | `#C8462B` | **Alerts, deltas, the physical button. Nothing else.** |
| `link` | `#0AA2C0` | Web only — hyperlinks and interactive web affordances |

### The signal-colour rule

`signal` is the single most important constraint in this document. Braun's clocks are
entirely grey and black except for one yellow hand — the colour *is* the information.

`signal` may appear on:

- an out-of-range alert (high/low threshold crossed)
- the current-value dot at the leading edge of a trend line
- a delta figure (`+0.6 TODAY`)
- the one physical button on the display unit

`signal` must **not** appear on: headings, brand marks, decorative rules, borders, icons,
navigation, or anything that is present at rest on every screen. If it is always visible,
it has stopped meaning anything.

`link` (`#0AA2C0`) is explicitly a *web* colour and must not appear on device hardware or
on the e-ink face. This keeps the physical product from inheriting a screen-only palette.

---

## 3. Typography

One grotesque, tabular figures, two sizes per surface.

| Role | Recommendation |
|------|----------------|
| System (no webfont) | `Helvetica Neue, Arial, sans-serif` |
| Shipping a webfont | **Space Grotesk** (more 1960s technical-instrument flavour) or **Inter Tight** (more neutral/Apple) |
| Embedded / e-ink | Any heavy grotesque rasterised at fixed sizes; flat terminals, tabular digits |

Rules:

- **Tabular figures are mandatory** anywhere a number updates in place. Proportional
  digits cause the reading to jitter horizontally on every refresh, which reads as
  instability on e-ink.
- **Two type sizes per surface**, maximum. A hero numeral and a label size. Anything that
  wants a third size wants to be removed instead.
- **Labels**: 12–13px, uppercase, letterspaced 2–5px, weight 500, in `grey`.
- **Sentence case in prose and on the web**; uppercase reserved for the short instrument
  labels on the device face, where it is a deliberate 1960s panel-legend idiom.
- **Negative tracking on the hero numeral** (approximately −4 at 132px) — large grotesque
  digits set at default tracking look loose.

---

## 4. E-ink display face

Specified at **400 × 300 px**, the native resolution of a 4.2" Waveshare / GDEY panel, so
the layout maps 1:1 to real pixels with no scaling.

Coordinates below are in panel space (origin at the panel's top-left, not the bezel).

| Element | Position | Size / weight | Colour |
|---------|----------|---------------|--------|
| Location label (`POOL`) | x 30, baseline y 36 | 13px / 500 / +4 tracking / uppercase | `ink` |
| Radio strength glyph | x ~300–320, y ~22–40 | 1.2px stroke arcs | `ink` |
| Battery glyph | x 330–360, y 25–37 | 1.2px stroke, solid fill bar | `ink` |
| Hero numeral (`27.4`) | x 28, baseline y 180 | 132px / 600 / −4 tracking | `ink` |
| Unit (`°C`) | x 312, baseline y 120 | 34px / 500 | `ink` |
| Divider rule | x 30 → 370, y 212 | 0.8px | `ink` |
| `MIN` / `MAX` labels | x 30 / x 108, baseline y 242 | 13px / 500 / +2 tracking | `grey-dark` |
| Min / max values | x 65 / x 146, baseline y 242 | 13px / 500 / +1 tracking | `ink` |
| 24 h sparkline | x 242 → 362, y ~225–247 | 1.6px stroke, round joins | `ink` |
| Current-value dot | leading edge of sparkline | r 4, filled | `signal` |
| Freshness stamp | x 30, baseline y 275 | 12px / 500 / +2.5 tracking | `grey` |
| Daily delta | x 370, right-aligned, baseline y 275 | 12px / 500 / +2.5 tracking | `signal` |

### Freshness is load-bearing

This is the most important functional element on the face after the reading itself.

Threshold reporting means a thermally flat pool transmits nothing for hours. An e-ink
panel retains its last image with zero power — including when the receiver has crashed,
lost the sensor, or run flat. **A face without a freshness stamp is indistinguishable
from a broken one.**

Recommended behaviour:

1. Sensor sends a keepalive at a fixed maximum interval (already on the roadmap for the
   Matter build) regardless of threshold.
2. Display shows relative age: `UPDATED 2 MIN AGO`, `UPDATED 3 H AGO`.
3. Past a staleness ceiling (suggest 2× the keepalive interval), the age stamp switches to
   `signal` and the hero numeral drops to `grey` — the reading is still shown, but it is
   visibly demoted rather than silently trusted.
4. Never blank the number and never substitute `--.-` while a real last-known value
   exists. Showing the old value with honest provenance is more useful than showing
   nothing.

This is the same honesty principle already applied to the battery characteristic, which
fails its read rather than reporting a fabricated level.

---

## 5. Enclosure — the two products

Splitting the sensor and the display into separate products lets each be honest about
what it is. The design logic inverts between them.

### 5.1 Sensor float (battery)

- **No screen, no labels, no branding on the top face.** The top face is the surface that
  gets sun, algae and pool chemicals; it is also the surface nobody reads. Leave it blank.
- Matte bone (`#E9E5DA`) ASA or PETG. Matte, not gloss — gloss shows every water spot and
  reads as cheap in a way matte does not.
- One status LED behind the shell, completely invisible when off. No bezel ring, no light
  pipe collar.
- Wordmark moulded (not printed) into the underside, where only the owner ever sees it.
- **Material honesty**: treat the O-ring seam as a deliberate horizontal line at a
  considered height, not something to disguise. Braun did the same with speaker-grille
  seams. A visible, straight, intentional parting line reads better than a hidden,
  slightly wavy one.
- Generous corner radius on a small object — this is the T3/iPod cue. Softened square,
  never a blob.

### 5.2 Display receiver (mains / USB)

- Bone shell, `paper` panel, ~30px bezel radius at the scale mocked up.
- Chin below the panel carries the wordmark in `grey` at 12px / +5 tracking, and one
  circular `signal` button, unlabeled.
- **One button, no label.** If the button needs a label, the interaction is too complex
  and should be removed. Suggested function: force refresh / re-sync, with a long press
  for pairing.
- Should sit on a shelf like an object, not clip to a wall like a sensor.

---

## 6. Web

The site should use the same palette, not a parallel one.

- Background `paper`, text `ink`, secondary `grey`, rules `edge`.
- `link` (`#0AA2C0`) for hyperlinks only.
- `signal` for genuine warnings only — the security section's honest limitations
  (unsigned BLE OTA, open AP, unencrypted ESP-NOW) are exactly the right use; feature
  headings are not.
- Same two-size type discipline: one heading scale, one body scale, labels at 13px caps.
- The existing dark theme colour (`#061e29`) conflicts with this palette. Either retire it
  in favour of an `ink`-based dark surface, or keep it deliberately as a distinct
  "marketing hero" treatment and document that split.

---

## 7. Open questions

These change the layout materially and should be resolved before CAD or panel selection:

1. **Is the display mains-only on a shelf, or battery-capable for poolside use?**
   Battery operation constrains refresh rate and rules out partial-refresh-heavy layouts.
2. **One sensor or several?** A multi-sensor face cannot lead with a 132px numeral. The
   single-sensor layout above does not scale to three zones — that needs a separate,
   list-oriented layout, not a shrunken version of this one.
3. **Panel colour depth.** A 2-colour (black/white) panel forces `signal` to be expressed
   as weight or position instead. A 3-colour (black/white/red) panel renders `signal`
   natively — `#C8462B` was chosen partly because it is close to typical e-ink red.
4. **Does the sensor float ever need a display at all**, or is the split permanent? If
   permanent, the float's industrial design can get simpler still.

---

## 8. Quick checklist

Before shipping any surface, check:

- [ ] Is `signal` used exactly once, and does it mean something?
- [ ] Are there more than two type sizes on this surface?
- [ ] Are the figures tabular?
- [ ] Does every reading carry its age?
- [ ] Is anything shown that the hardware cannot actually measure?
- [ ] What breaks if I delete the least important element here?

---

## Appendix — reference mockup (SVG)

Bezel-and-panel mockup at the proportions described above. Panel content sits at
x 140–540, y 60–360 in this coordinate space (400 × 300 native).

Editable source files for all the design mockups live in `docs/assets/`:
`akvalink_eink_display_face_400x300.{svg,png}` (the panel face below),
plus `akvalink_console_display_industrial_design.svg` and
`akvalink_float_sensor_industrial_design.svg` — the sources of the PNG
renders shown in the web page's Product design section (`web/assets/`).

```svg
<svg width="100%" viewBox="0 0 680 440" role="img" xmlns="http://www.w3.org/2000/svg">
  <title>AkvaLink e-ink display concept</title>

  <rect x="100" y="40" width="480" height="380" rx="30" fill="#E9E5DA" stroke="#CBC5B5" stroke-width="0.5"/>
  <rect x="140" y="60" width="400" height="300" rx="3" fill="#F8F6F0" stroke="#D5D0C2" stroke-width="0.5"/>

  <text x="170" y="96" font-family="Helvetica Neue, Arial, sans-serif" font-size="13" font-weight="500" letter-spacing="4" fill="#1C1C1A">POOL</text>

  <rect x="470" y="85" width="26" height="12" rx="2" fill="none" stroke="#1C1C1A" stroke-width="1.2"/>
  <rect x="497" y="88" width="3" height="6" rx="1" fill="#1C1C1A"/>
  <rect x="472.5" y="87.5" width="15" height="7" fill="#1C1C1A"/>
  <circle cx="446" cy="91" r="2" fill="#1C1C1A"/>
  <path d="M451 96 A9 9 0 0 0 451 86" fill="none" stroke="#1C1C1A" stroke-width="1.2" stroke-linecap="round"/>
  <path d="M456 100 A15 15 0 0 0 456 82" fill="none" stroke="#1C1C1A" stroke-width="1.2" stroke-linecap="round"/>

  <text x="168" y="240" font-family="Helvetica Neue, Arial, sans-serif" font-size="132" font-weight="600" letter-spacing="-4" fill="#1C1C1A">27.4</text>
  <text x="452" y="180" font-family="Helvetica Neue, Arial, sans-serif" font-size="34" font-weight="500" fill="#1C1C1A">°C</text>

  <line x1="170" y1="272" x2="510" y2="272" stroke="#1C1C1A" stroke-width="0.8"/>

  <text x="170" y="302" font-family="Helvetica Neue, Arial, sans-serif" font-size="13" font-weight="500" letter-spacing="2" fill="#77746C">MIN</text>
  <text x="205" y="302" font-family="Helvetica Neue, Arial, sans-serif" font-size="13" font-weight="500" letter-spacing="1" fill="#1C1C1A">24.1</text>
  <text x="248" y="302" font-family="Helvetica Neue, Arial, sans-serif" font-size="13" font-weight="500" letter-spacing="2" fill="#77746C">MAX</text>
  <text x="286" y="302" font-family="Helvetica Neue, Arial, sans-serif" font-size="13" font-weight="500" letter-spacing="1" fill="#1C1C1A">28.9</text>

  <polyline points="382,306 397,304 412,307 427,301 442,296 457,298 472,291 487,289 502,285" fill="none" stroke="#1C1C1A" stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round"/>
  <circle cx="502" cy="285" r="4" fill="#C8462B"/>

  <text x="170" y="335" font-family="Helvetica Neue, Arial, sans-serif" font-size="12" font-weight="500" letter-spacing="2.5" fill="#8A8781">UPDATED 2 MIN AGO</text>
  <text x="510" y="335" text-anchor="end" font-family="Helvetica Neue, Arial, sans-serif" font-size="12" font-weight="500" letter-spacing="2.5" fill="#C8462B">+0.6 TODAY</text>

  <text x="170" y="399" font-family="Helvetica Neue, Arial, sans-serif" font-size="12" font-weight="500" letter-spacing="5" fill="#96918A">AKVALINK</text>
  <circle cx="508" cy="394" r="11" fill="#C8462B"/>
</svg>
```

---

Apache-2.0, same as the rest of AkvaLink. Braun and Apple are named here only as design
references; no affiliation is implied.
