#!/usr/bin/env python3
"""Export the Sephr app icon at every macOS-required size from the brand master.

Reads the canonical brand asset `sephr/Resources/AppIcon-source.png` (a square
RGBA master, 1024px or larger — currently the 2048px light icon) and downscales
it into the 10 PNGs under
`sephr/Resources/Assets.xcassets/AppIcon.appiconset/` matching the
Contents.json declared slots, plus a sibling `AppIcon.icns` for code paths that
look for an icns rather than the asset catalog (SPM doesn't compile xcassets, so
make_app.sh ships the raw catalog *and* the .icns).

The master is treated as the finished artwork: it is resized as-is with no
added rounded-rectangle mask or glyph — modern macOS icons carry their own
squircle shape in the source PNG. To swap in a new brand icon, replace
`sephr/Resources/AppIcon-source.png` and re-run this script.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys

try:
    from PIL import Image
except ImportError:
    sys.stderr.write(
        "[sephr] Pillow missing — install via `pip3 install pillow`.\n"
    )
    raise SystemExit(1)


ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "sephr" / "Resources" / "AppIcon-source.png"
ASSET_SET = ROOT / "sephr" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

# (size_px, filename) — the asset-catalog slots. The @2x files are the same
# pixel dimensions as the next size up's 1x, per the macOS convention.
SLOTS = [
    (16,   "sephr_16x16.png"),
    (32,   "sephr_16x16@2x.png"),
    (32,   "sephr_32x32.png"),
    (64,   "sephr_32x32@2x.png"),
    (128,  "sephr_128x128.png"),
    (256,  "sephr_128x128@2x.png"),
    (256,  "sephr_256x256.png"),
    (512,  "sephr_256x256@2x.png"),
    (512,  "sephr_512x512.png"),
    (1024, "sephr_512x512@2x.png"),
]

# iconutil expects icon_<size>x<size>[@2x].png naming inside the .iconset.
ICNS_SLOTS = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

# Catalog metadata — one mac entry per (size, scale) pair, matching SLOTS.
CATALOG_IMAGES = [
    ("16x16",   "1x", "sephr_16x16.png"),
    ("16x16",   "2x", "sephr_16x16@2x.png"),
    ("32x32",   "1x", "sephr_32x32.png"),
    ("32x32",   "2x", "sephr_32x32@2x.png"),
    ("128x128", "1x", "sephr_128x128.png"),
    ("128x128", "2x", "sephr_128x128@2x.png"),
    ("256x256", "1x", "sephr_256x256.png"),
    ("256x256", "2x", "sephr_256x256@2x.png"),
    ("512x512", "1x", "sephr_512x512.png"),
    ("512x512", "2x", "sephr_512x512@2x.png"),
]


def load_master() -> "Image.Image":
    if not SOURCE.exists():
        sys.stderr.write(
            f"[sephr] brand master not found: {SOURCE}\n"
            "        Drop the square icon PNG there and re-run.\n"
        )
        raise SystemExit(1)
    img = Image.open(SOURCE).convert("RGBA")
    w, h = img.size
    if w != h:
        sys.stderr.write(
            f"[sephr] warning: master is {w}x{h}, not square — "
            "Apple icons must be square.\n"
        )
    if min(w, h) < 1024:
        sys.stderr.write(
            f"[sephr] warning: master is only {w}x{h}; "
            "1024px+ recommended so the 512@2x slot isn't upscaled.\n"
        )
    return img


def resized(master: "Image.Image", size: int) -> "Image.Image":
    if master.size == (size, size):
        return master.copy()
    return master.resize((size, size), Image.LANCZOS)


def main() -> int:
    master = load_master()

    # 1. Asset-catalog PNGs.
    ASSET_SET.mkdir(parents=True, exist_ok=True)
    for size, fname in SLOTS:
        resized(master, size).save(ASSET_SET / fname, format="PNG")
        print(f"  {fname}  {size}x{size}")

    (ASSET_SET / "Contents.json").write_text(
        json.dumps(
            {
                "info": {"version": 1, "author": "sephr"},
                "images": [
                    {"idiom": "mac", "size": size, "scale": scale,
                     "filename": fname}
                    for size, scale, fname in CATALOG_IMAGES
                ],
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n"
    )

    # 2. AppIcon.icns (for the Finder/Dock icon via CFBundleIconFile).
    iconset_dir = ROOT / "sephr" / "Resources" / "AppIcon.iconset"
    iconset_dir.mkdir(exist_ok=True)
    for size, name in ICNS_SLOTS:
        resized(master, size).save(iconset_dir / name, format="PNG")
    out_icns = ROOT / "sephr" / "Resources" / "AppIcon.icns"
    subprocess.run(
        ["iconutil", "-c", "icns", "-o", str(out_icns), str(iconset_dir)],
        check=True,
    )
    print(f"\n  → {out_icns}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
