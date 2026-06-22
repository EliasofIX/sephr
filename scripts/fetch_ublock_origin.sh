#!/usr/bin/env bash
# Downloads and unpacks uBlock Origin for Sephr's built-in component
# extension. Idempotent — skips when manifest.json is already present.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="sephrium/extensions/ublock_origin"
MARKER="$DEST/manifest.json"

if [ -f "$MARKER" ]; then
    VERSION="$(python3 -c "import json; v=json.load(open('$MARKER'))['version']; print(v['version'] if isinstance(v, dict) else v)")"
    echo "[sephr] uBlock Origin already present ($VERSION) → $DEST"
    exit 0
fi

UBO_REPO="https://api.github.com/repos/gorhill/uBlock/releases/latest"
echo "[sephr] Resolving latest uBlock Origin release..."
ASSET_URL="$(curl -fsSL "$UBO_REPO" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('assets', []):
    n = a.get('name', '')
    if 'chromium' in n and n.endswith('.zip'):
        print(a['browser_download_url'])
        break
")"

if [ -z "$ASSET_URL" ]; then
    echo "[sephr] FAIL: no chromium .zip asset on latest uBlock release" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ZIP="$TMP/ublock.zip"
echo "[sephr] Downloading $ASSET_URL ..."
curl -fsSL -o "$ZIP" "$ASSET_URL"

rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q "$ZIP" -d "$TMP/extracted"

# Release zips ship a single top-level directory (uBlock0_x.y.z/).
ROOT="$(find "$TMP/extracted" -maxdepth 1 -mindepth 1 -type d | head -1)"
if [ -z "$ROOT" ] || [ ! -f "$ROOT/manifest.json" ]; then
    echo "[sephr] FAIL: unexpected uBlock zip layout" >&2
    exit 1
fi

cp -R "$ROOT/." "$DEST/"

# ComponentLoader requires the Chrome Web Store public key to derive the
# stable extension id. Release zips omit it; inject before packaging.
python3 - "$MARKER" <<'PY'
import json, sys
path = sys.argv[1]
KEY = (
    "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmJNzUNVjS6Q1qe0NRqpmfX/"
    "oSJdgauSZNdfeb5RV1Hji21vX0TivpP5gq0fadwmvmVCtUpOaNUopgejiUFm/iKHPs0o"
    "3x7hyKk/eX0t2QT3OZGdXkPiYpTEC0f0p86SQaLoA2eHaOG4uCGi7sxLJmAXc6IsxGKV"
    "klh7cCoLUgWEMnj8ZNG2Y8UKG3gBdrpES5hk7QyFDMraO79NmSlWRNgoJHX6XRoY66o"
    "YThFQad8KL8q3pf3Oe8uBLKywohU0ZrDPViWHIszXoE9HEvPTFAbHZ1umINni4W/YVs+"
    "fhqHtzRJcaKJtsTaYy+cholu5mAYeTZqtHf6bcwJ8t9i2afwIDAQAB"
)
with open(path, encoding="utf-8") as f:
    manifest = json.load(f)
if "key" not in manifest:
    manifest["key"] = KEY
    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
PY

VERSION="$(python3 -c "import json; v=json.load(open('$MARKER'))['version']; print(v['version'] if isinstance(v, dict) else v)")"
echo "[sephr] uBlock Origin $VERSION → $DEST"
