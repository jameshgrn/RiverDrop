#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_PNG="${1:-$REPO_ROOT/.generated/icon_1024_source.png}"
APPICONSET_DIR="${2:-$REPO_ROOT/RiverDrop/Assets.xcassets/AppIcon.appiconset}"

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "Error: source PNG not found: $SOURCE_PNG" >&2
  echo "Fix: run scripts/generate_icon_with_gemini.sh first, or pass a valid 1024 PNG path." >&2
  exit 1
fi

mkdir -p "$APPICONSET_DIR"

# Ensure source is a canonical 1024x1024 PNG.
TMP_DIR="$(mktemp -d -t riverdrop_icon_XXXXXX)"
CANONICAL_SOURCE="$TMP_DIR/canonical.png"
trap 'rm -rf "$TMP_DIR"' EXIT
sips -s format png -z 1024 1024 "$SOURCE_PNG" --out "$CANONICAL_SOURCE" >/dev/null

make_icon() {
  local size="$1"
  local filename="$2"
  sips -s format png -z "$size" "$size" "$CANONICAL_SOURCE" --out "$APPICONSET_DIR/$filename" >/dev/null
}

make_icon 16 "icon_16x16.png"
make_icon 32 "icon_16x16@2x.png"
make_icon 32 "icon_32x32.png"
make_icon 64 "icon_32x32@2x.png"
make_icon 128 "icon_128x128.png"
make_icon 256 "icon_128x128@2x.png"
make_icon 256 "icon_256x256.png"
make_icon 512 "icon_256x256@2x.png"
make_icon 512 "icon_512x512.png"
make_icon 1024 "icon_512x512@2x.png"

cat >"$APPICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "Wrote AppIcon set: $APPICONSET_DIR"
