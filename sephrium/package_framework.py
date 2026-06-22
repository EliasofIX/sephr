#!/usr/bin/env python3
"""Packages Chromium build output for CAL link + Sephr.app runtime.

Phase 2 produces TWO sibling artefacts under `build/`:

  1. `Sephr Framework.framework/` — the real, canonical Apple framework
     bundle (named via the BRANDING patch, 014-brand-mac-product-names).
     Inner dylib stays named "Sephr Framework" because
     chrome/app/chrome_exe_main_mac.cc hard-codes
     `PRODUCT_FULLNAME_STRING " Framework"` in the helpers' dlopen path.
     Layout is the standard one Apple expects (Versions/<v>/ +
     top-level symlinks). NO extra symlinks at the root — `codesign`
     would otherwise flag them as "unsealed contents".

  2. `Sephrium.framework/` — a fresh, tiny stub framework that exists
     solely so CAL's `-framework Sephrium` link succeeds. Contains:
       Sephrium  → ../Sephr Framework.framework/Sephr Framework
       Headers/cal_bridge.h
     dyld's @rpath resolution follows the relative symlink to the real
     dylib at load time. install_name on the real dylib is set to
     `@rpath/Sephrium.framework/Sephrium` so dyld dedupes against any
     direct dlopen of the same image elsewhere in Chromium.

`scripts/make_app.sh` mirrors this layout inside the .app bundle.

Pass --release to package out/Release (LTO/official) instead of out/Fast.
"""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys

FRAMEWORK_NAME = "Sephrium"
# Inner Chromium framework bundle name. Set by the BRANDING patch
# (014-brand-mac-product-names) — chromium's chrome_framework GN target
# emits `<PRODUCT_FULLNAME> Framework.framework`, so flipping
# PRODUCT_FULLNAME=Sephr in BRANDING produces "Sephr Framework". If you
# ever rebuild with an unpatched BRANDING this needs to flip back to
# "Chromium Framework" to match disk.
CHROMIUM_FRAMEWORK = "Sephr Framework"
ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD_DIR = ROOT / "build"
CF_OUT = BUILD_DIR / f"{CHROMIUM_FRAMEWORK}.framework"
SEPHRIUM_OUT = BUILD_DIR / f"{FRAMEWORK_NAME}.framework"

# The .chromium-src/ tree still uses the pre-2026-06-04 `agena/` path
# (the Agena→Sephr rebrand explicitly skipped .chromium-src/ — see the
# rebrand-agena-to-sephr memory). Patch 002 carries the rename and will
# move this to chrome/sephr/cal_bridge/ once the patch series is
# regenerated from the WT. Until then we read where the source actually
# is — falling back to chrome/sephr/ if the rebrand has happened.
_SEPHR_CAL_BRIDGE = (ROOT / ".chromium-src" / "src" / "chrome" /
                     "sephr" / "cal_bridge" / "cal_bridge.h")
_AGENA_CAL_BRIDGE = (ROOT / ".chromium-src" / "src" / "chrome" /
                     "agena" / "cal_bridge" / "cal_bridge.h")
CAL_BRIDGE_HEADER = (_SEPHR_CAL_BRIDGE if _SEPHR_CAL_BRIDGE.exists()
                     else _AGENA_CAL_BRIDGE)

UBLOCK_ORIGIN_SRC = ROOT / "sephrium" / "extensions" / "ublock_origin"


def _bundle_ublock_origin(resources_dir: pathlib.Path) -> None:
    """Copy the unpacked uBlock Origin tree into the framework Resources/."""
    if not UBLOCK_ORIGIN_SRC.is_dir():
        print("[sephr] WARN: uBlock Origin not fetched — run "
              "scripts/fetch_ublock_origin.sh", file=sys.stderr)
        return
    dest = resources_dir / "ublock_origin"
    if dest.exists():
        shutil.rmtree(dest)
    print("[sephr] bundling uBlock Origin into framework Resources/ ...")
    shutil.copytree(UBLOCK_ORIGIN_SRC, dest)


def chromium_version() -> str:
    txt = ROOT / "sephrium" / "chromium_version.txt"
    return txt.read_text().strip()


def package(build_out: pathlib.Path) -> None:
    cf_src = build_out / f"{CHROMIUM_FRAMEWORK}.framework"
    if not cf_src.exists():
        bare = build_out / "libchrome.dylib"
        if not bare.exists():
            print(f"[sephr] no framework found in {build_out}", file=sys.stderr)
            sys.exit(1)
        return _package_bare(bare)

    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    # --- 1. Real Chromium Framework bundle ---------------------------------
    # Wipe both sibling outputs and copy fresh. SEPHRIUM_OUT might be a
    # symlink left over from an earlier run; `shutil.rmtree` on a symlink
    # follows the link, so unlink first.
    if SEPHRIUM_OUT.is_symlink():
        SEPHRIUM_OUT.unlink()
    elif SEPHRIUM_OUT.exists():
        shutil.rmtree(SEPHRIUM_OUT)
    if CF_OUT.is_symlink():
        CF_OUT.unlink()
    elif CF_OUT.exists():
        shutil.rmtree(CF_OUT)

    print(f"[sephr] copying {cf_src.name} (~510 MB)...")
    shutil.copytree(cf_src, CF_OUT, symlinks=True)

    version = chromium_version()
    versioned = CF_OUT / "Versions" / version
    inner_binary = versioned / CHROMIUM_FRAMEWORK
    if not inner_binary.exists():
        print(f"[sephr] missing inner dylib at {inner_binary}", file=sys.stderr)
        sys.exit(1)

    # Strip non-canonical top-level symlinks Apple's codesign rejects as
    # "unsealed contents." Older packaging runs leave Sephrium + Headers
    # at the root; canonical layout only has Versions + the standard
    # binary/Helpers/Libraries/Resources symlinks.
    for stray in ("Sephrium", "Headers"):
        leftover = CF_OUT / stray
        if leftover.is_symlink() or leftover.exists():
            leftover.unlink()

    # install_name = the inner framework's real bundle path. Sephr's
    # LC_LOAD_DYLIB inherits this at swift-build link time and dyld
    # resolves directly to Contents/Frameworks/Sephr Framework.framework
    # at runtime. We used to use @rpath/Sephrium.framework/Sephrium for
    # an old "umbrella shim" model — but post-2026-06-05 the inner
    # framework directly exports the _Sephrium* C ABI (no shim needed),
    # and shipping a Sephrium.framework symlink wrapper breaks codesign
    # (main binary must be a regular file, not a symlink). make_app.sh
    # no longer copies Sephrium.framework into the .app at all.
    subprocess.run(
        ["install_name_tool", "-id",
         f"@rpath/{CHROMIUM_FRAMEWORK}.framework/{CHROMIUM_FRAMEWORK}",
         str(inner_binary)],
        check=True,
    )

    # --- 2. Stub Sephrium.framework for CAL link ----------------------------
    # Just enough framework structure for `-framework Sephrium` to resolve.
    # The Sephrium binary is a relative symlink to the real Chromium Framework
    # dylib — dyld follows it at load time.
    SEPHRIUM_OUT.mkdir(parents=True)
    (SEPHRIUM_OUT / FRAMEWORK_NAME).symlink_to(
        pathlib.Path("..") / f"{CHROMIUM_FRAMEWORK}.framework" /
        CHROMIUM_FRAMEWORK
    )
    headers_dir = SEPHRIUM_OUT / "Headers"
    headers_dir.mkdir()
    if CAL_BRIDGE_HEADER.exists():
        shutil.copy(CAL_BRIDGE_HEADER, headers_dir / "cal_bridge.h")
    headers_overlay = ROOT / "sephrium" / "cal_headers"
    if headers_overlay.exists():
        for h in headers_overlay.rglob("*.h"):
            shutil.copy(h, headers_dir / h.name)

    # --- 3. Sign the real bundle. The stub Sephrium.framework is just
    # symlinks and headers; codesign doesn't bother with it.
    subprocess.run(
        ["codesign", "--force", "--sign", "-", str(CF_OUT)],
        check=True,
    )

    _bundle_ublock_origin(versioned / "Resources")

    print(f"[sephr] packaged {CF_OUT} + {SEPHRIUM_OUT.name} stub")
    helpers = CF_OUT / "Helpers"
    if helpers.exists():
        n = sum(1 for _ in helpers.iterdir())
        print(f"[sephr]   Helpers/ contains {n} entries")


def _package_bare(dylib: pathlib.Path) -> None:
    """Bare package: just the dylib + Headers in Sephrium.framework.

    No helpers, no resources — CAL links but ChromeMain cannot boot. Used
    when build_out hasn't produced the full chrome_framework bundle target
    (component / dev builds).
    """
    if SEPHRIUM_OUT.is_symlink():
        SEPHRIUM_OUT.unlink()
    elif SEPHRIUM_OUT.exists():
        shutil.rmtree(SEPHRIUM_OUT)
    SEPHRIUM_OUT.mkdir(parents=True)
    target = SEPHRIUM_OUT / FRAMEWORK_NAME
    shutil.copy(dylib, target)
    subprocess.run(
        ["install_name_tool", "-id",
         f"@rpath/{FRAMEWORK_NAME}.framework/{FRAMEWORK_NAME}", str(target)],
        check=True,
    )
    headers = SEPHRIUM_OUT / "Headers"
    headers.mkdir()
    if CAL_BRIDGE_HEADER.exists():
        shutil.copy(CAL_BRIDGE_HEADER, headers / "cal_bridge.h")
    subprocess.run(
        ["codesign", "--force", "--sign", "-", str(SEPHRIUM_OUT)],
        check=True,
    )
    print(f"[sephr] packaged BARE {SEPHRIUM_OUT} (no helpers, no resources)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", action="store_true",
                    help="Package out/Release (shippable LTO build) instead "
                         "of out/Fast (default inner-loop build).")
    args = ap.parse_args()
    out_name = "Release" if args.release else "Fast"
    package(ROOT / ".chromium-src" / "src" / "out" / out_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
