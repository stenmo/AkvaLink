#!/usr/bin/env python3
"""
generate_icon.py — Convert web/icon-maskable.svg to a 1024x1024 launcher icon PNG.

icon-maskable.svg has the drop centered inside the adaptive-icon safe zone with
the brand background baked in (favicon.svg alone is edge-to-edge with no
padding and gets clipped by circular/squircle OS icon masks). This script
renders it at icon resolution and saves it as app_flutter/assets/icon.png for
flutter_launcher_icons to consume.

Requirements (one of):
    pip install svglib reportlab Pillow   # preferred on Windows (no native libs)
    pip install cairosvg                  # alternative (needs libcairo DLL)
    Inkscape installed in PATH            # another alternative

Usage:
    python scripts/generate_icon.py

Then regenerate platform launcher icons:
    cd app_flutter && flutter pub run flutter_launcher_icons
"""

import io
import math
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SVG_PATH  = REPO_ROOT / "web" / "icon-maskable.svg"
OUT_PATH  = REPO_ROOT / "app_flutter" / "assets" / "icon.png"
SIZE = 1024

OUT_PATH.parent.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# 1. svglib + reportlab (pip install svglib reportlab Pillow)
# ---------------------------------------------------------------------------
def _via_svglib() -> bool:
    try:
        from svglib.svglib import svg2rlg          # type: ignore
        from reportlab.graphics import renderPM    # type: ignore
        from PIL import Image                      # type: ignore
    except (ImportError, OSError):
        # OSError: reportlab's PM backend can require a native cairo DLL
        # that isn't installed on Windows even when the Python packages are.
        return False

    drawing = svg2rlg(str(SVG_PATH))
    if drawing is None:
        print("svglib: could not parse SVG")
        return False

    scale = SIZE / max(drawing.width, drawing.height)
    drawing.width  *= scale
    drawing.height *= scale
    drawing.transform = (scale, 0, 0, scale, 0, 0)

    buf = io.BytesIO()
    renderPM.drawToFile(drawing, buf, fmt="PNG", dpi=72)
    buf.seek(0)

    img = Image.open(buf).resize((SIZE, SIZE), Image.LANCZOS)
    img.save(OUT_PATH, "PNG")
    return True


# ---------------------------------------------------------------------------
# 2. Inkscape CLI
# ---------------------------------------------------------------------------
def _via_inkscape() -> bool:
    import shutil, subprocess
    inkscape = shutil.which("inkscape")
    if not inkscape:
        return False
    r = subprocess.run(
        [inkscape, str(SVG_PATH),
         "--export-type=png", f"--export-filename={OUT_PATH}",
         f"--export-width={SIZE}", f"--export-height={SIZE}"],
        capture_output=True,
    )
    return r.returncode == 0 and OUT_PATH.exists()


# ---------------------------------------------------------------------------
# 3. Manual Pillow render — exact shapes from web/icon-maskable.svg
#    SVG viewport is 100x100; drop group is translate(23 20) scale(1.7)
#    applied on top of the 32x32 favicon shapes.
# ---------------------------------------------------------------------------
def _via_pillow() -> bool:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return False

    scale = SIZE / 100.0          # icon-maskable.svg viewBox is 100x100
    dscale = scale * 1.7          # drop group's extra scale(1.7)
    dx, dy = 23 * scale, 20 * scale  # drop group's translate(23 20)
    def s(v): return int(round(v * dscale + 0))
    def sx(v): return int(round(v * dscale + dx))
    def sy(v): return int(round(v * dscale + dy))

    img   = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw  = ImageDraw.Draw(img)

    # Brand colours from icon-maskable.svg / site theme.
    c_bg_top   = (10,  74,  90)   # #0a4a5a
    c_bg_bot   = (3,   63,  99)   # #033f63
    c_grad_top = (40,  194, 214)  # #28c2d6
    c_grad_bot = (10,  162, 192)  # #0aa2c0
    c_dark     = (22,  50,  63)   # #16323f
    c_shine    = (234, 247, 251)  # #eaf7fb

    # --- Full-bleed background (top to bottom across the whole square) -----
    for y in range(SIZE):
        t = y / SIZE
        r = int(c_bg_top[0] + (c_bg_bot[0] - c_bg_top[0]) * t)
        g = int(c_bg_top[1] + (c_bg_bot[1] - c_bg_top[1]) * t)
        b = int(c_bg_top[2] + (c_bg_bot[2] - c_bg_top[2]) * t)
        draw.line([(0, y), (SIZE - 1, y)], fill=(r, g, b, 255))

    # --- Water drop  M16 2 ... arc11 ... Z (inside the drop group) ---------
    # Lower circle centred at (16, 22) r=11, upper triangle to tip at (16, 2).
    cx, cy_arc, r_arc = sx(16), sy(22), s(11)

    # Build drop polygon: tip then arc of lower circle (left side → right side).
    poly = [(sx(16), sy(2))]  # tip
    n = 64
    for i in range(n + 1):
        angle = math.pi + math.pi * i / n  # 180° → 360° (bottom half)
        poly.append((int(cx + r_arc * math.cos(angle) * 0.94),
                     int(cy_arc + r_arc * math.sin(angle))))
    draw.polygon(poly, fill=(*c_grad_top, 255))

    # Full lower circle to cap the drop.
    draw.ellipse([cx - r_arc, cy_arc - r_arc, cx + r_arc, cy_arc + r_arc],
                 fill=(*c_grad_top, 255))

    # --- Sunglasses --------------------------------------------------------
    # Two rounded rectangles, bridge, temples (from SVG).
    rounding = max(2, int(s(1.8)))

    def lens(lx, ly, lw, lh):
        draw.rounded_rectangle(
            [sx(lx), sy(ly), sx(lx + lw), sy(ly + lh)],
            radius=rounding,
            fill=(*c_dark, 255),
        )

    lens(8.3, 16.4, 6.7, 4.9)    # left lens
    lens(17.0, 16.4, 6.7, 4.9)   # right lens

    sw = max(2, int(dscale * 1.5))

    # Bridge between lenses.
    draw.line([sx(15), sy(18.1), sx(17), sy(18.1)],
              fill=(*c_dark, 255), width=sw)

    # Temples (arms extending outward).
    draw.line([sx(8.3), sy(17.9), sx(6.2), sy(17.1)],
              fill=(*c_dark, 255), width=max(2, int(dscale * 1.4)))
    draw.line([sx(23.7), sy(17.9), sx(25.8), sy(17.1)],
              fill=(*c_dark, 255), width=max(2, int(dscale * 1.4)))

    # Lens shine (diagonal lines, 50% opacity).
    sw2 = max(2, int(dscale * 1.0))
    shine = (*c_shine, 128)
    draw.line([sx(9.7), sy(20.3), sx(12.5), sy(17.3)],  fill=shine, width=sw2)
    draw.line([sx(18.3), sy(20.3), sx(21.1), sy(17.3)], fill=shine, width=sw2)

    # Smirk (Q curve approximated as polyline).
    smirk = (*c_shine, 220)
    sw3 = max(3, int(dscale * 1.8))
    draw.line([sx(12.6), sy(25.1), sx(16.0), sy(26.7), sx(19.8), sy(24.7)],
              fill=smirk, width=sw3, joint="curve")

    # Flatten RGBA -> RGB (background is already full-bleed, alpha is 255 everywhere).
    img.convert("RGB").save(OUT_PATH, "PNG")
    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
print(f"Source : {SVG_PATH}")
print(f"Output : {OUT_PATH}  ({SIZE}x{SIZE})")

if _via_svglib():
    print("Rendered via svglib (direct SVG conversion).")
elif _via_inkscape():
    print("Rendered via Inkscape.")
elif _via_pillow():
    print("Rendered via Pillow (manual shapes from icon-maskable.svg).")
else:
    sys.exit(
        "ERROR: no renderer available.\n"
        "Install one of:  pip install svglib reportlab Pillow\n"
        "             or  install Inkscape and add it to PATH"
    )

print()
print("Next: regenerate all platform launcher icons:")
print("    cd app_flutter && flutter pub run flutter_launcher_icons")
