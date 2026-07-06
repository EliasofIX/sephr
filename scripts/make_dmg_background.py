#!/usr/bin/env python3
"""Render the Sephr DMG background image.

Produces two PNGs — `build/dmg_background.png` (660x440 @1x) and
`build/dmg_background@2x.png` (1320x880) — that `scripts/make_dmg.sh`
combines into a multi-rep .tiff so Finder picks the retina rep on hi-DPI
displays.

Palette is sampled from the app icon: cream #ECE9E2 + jet black. The
background carries only typography and a hairline arrow; the app and
Applications icons are positioned on top by the AppleScript in
make_dmg.sh.
"""
from __future__ import annotations

import pathlib
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.stderr.write("[dmg] Pillow missing — install via `pip3 install pillow`.\n")
    raise SystemExit(1)


ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_1X = ROOT / "build" / "dmg_background.png"
OUT_2X = ROOT / "build" / "dmg_background@2x.png"

# Logical window dimensions (must match AppleScript window bounds).
W, H = 660, 440

# Brand palette (sampled from AppIcon-source.png).
CREAM = (236, 233, 226, 255)
INK = (12, 12, 12, 255)
INK_SOFT = (12, 12, 12, 90)        # arrow + hairline
INK_FAINT = (12, 12, 12, 50)       # micro text
INK_GHOST = (12, 12, 12, 18)       # icon-slot rings

# Font paths — fall back gracefully if the system layout differs.
SFNS = "/System/Library/Fonts/SFNS.ttf"
SFNS_ITALIC = "/System/Library/Fonts/SFNSItalic.ttf"
SFMONO = "/System/Library/Fonts/SFNSMono.ttf"


def _font(path: str, size: int, weight: int | None = None) -> ImageFont.FreeTypeFont:
    """Load `path` at `size`. If it's a variable font, apply weight axis."""
    fnt = ImageFont.truetype(path, size=size)
    if weight is not None:
        try:
            fnt.set_variation_by_axes([weight])
        except Exception:
            pass
    return fnt


def render(scale: int) -> Image.Image:
    s = scale
    w, h = W * s, H * s
    img = Image.new("RGBA", (w, h), CREAM)
    d = ImageDraw.Draw(img, "RGBA")

    # Wordmark — "SEPHR" widely tracked, top center.
    word = "S E P H R"
    word_font = _font(SFNS, 34 * s, weight=300)  # light
    bbox = d.textbbox((0, 0), word, font=word_font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    d.text(
        ((w - tw) / 2 - bbox[0], 64 * s - bbox[1]),
        word,
        font=word_font,
        fill=INK,
    )

    # Subtitle — tiny mono, generous tracking.
    sub_text = "T H E   D O T T E D   B R O W S E R"
    try:
        sub_font = _font(SFMONO, 9 * s, weight=400)
    except OSError:
        sub_font = _font(SFNS, 9 * s, weight=400)
    sb = d.textbbox((0, 0), sub_text, font=sub_font)
    sw = sb[2] - sb[0]
    d.text(
        ((w - sw) / 2 - sb[0], 108 * s - sb[1]),
        sub_text,
        font=sub_font,
        fill=INK_FAINT,
    )

    # Icon slot centers (must match AppleScript positions exactly).
    app_cx, app_cy = 175 * s, 230 * s
    apps_cx, apps_cy = 485 * s, 230 * s
    icon_r = 64 * s  # 128 / 2

    # Ghost rings behind each icon slot — barely visible cream-on-cream.
    ring_w = max(1, s)
    for cx, cy in ((app_cx, app_cy), (apps_cx, apps_cy)):
        d.ellipse(
            (cx - icon_r - 6 * s, cy - icon_r - 6 * s,
             cx + icon_r + 6 * s, cy + icon_r + 6 * s),
            outline=INK_GHOST, width=ring_w,
        )

    # Hairline arrow connecting the slots.
    arrow_y = app_cy
    arrow_x0 = app_cx + icon_r + 22 * s
    arrow_x1 = apps_cx - icon_r - 22 * s
    line_w = max(1, int(round(1.4 * s)))
    d.line(
        (arrow_x0, arrow_y, arrow_x1 - 6 * s, arrow_y),
        fill=INK_SOFT, width=line_w,
    )
    # Arrowhead — two short angled strokes.
    head = 7 * s
    d.line(
        (arrow_x1 - head, arrow_y - head,
         arrow_x1, arrow_y),
        fill=INK_SOFT, width=line_w,
    )
    d.line(
        (arrow_x1 - head, arrow_y + head,
         arrow_x1, arrow_y),
        fill=INK_SOFT, width=line_w,
    )

    # Footer hint — small italic serif feel via SF italic.
    try:
        hint_font = _font(SFNS_ITALIC, 12 * s, weight=400)
    except OSError:
        hint_font = _font(SFNS, 12 * s, weight=400)
    hint = "Drag Sephr onto the Applications folder"
    hb = d.textbbox((0, 0), hint, font=hint_font)
    hw = hb[2] - hb[0]
    d.text(
        ((w - hw) / 2 - hb[0], 386 * s - hb[1]),
        hint,
        font=hint_font,
        fill=(12, 12, 12, 130),
    )

    return img


def main() -> int:
    OUT_1X.parent.mkdir(parents=True, exist_ok=True)
    render(1).save(OUT_1X, format="PNG")
    render(2).save(OUT_2X, format="PNG")
    print(f"  → {OUT_1X.relative_to(ROOT)}  ({W}x{H})")
    print(f"  → {OUT_2X.relative_to(ROOT)}  ({W*2}x{H*2})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
