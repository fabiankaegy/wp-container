#!/usr/bin/env bash
#
# make-icons.sh — render every PNG copy of the app icon from the Icon Composer
# source, WPContainer/AppIcon.icon.
#
# The .icon bundle is the source of truth: Xcode compiles it into the app
# directly. This script only refreshes the flat PNGs derived from it:
#   - WPContainer/Assets.xcassets/AppIcon.appiconset  (pre-.icon fallback)
#   - docs/assets/icon.png                             (README)
#   - website/assets/icon.png + favicon-128.png        (marketing site)
#
# Edit the icon in Icon Composer, then re-run this script.
#
# Requirements: Xcode with Icon Composer (provides `ictool`).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/WPContainer/AppIcon.icon"
APPICONSET="$ROOT_DIR/WPContainer/Assets.xcassets/AppIcon.appiconset"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"

if [[ ! -x "$ICTOOL" ]]; then
  echo "error: ictool not found at $ICTOOL (needs Xcode 26+ with Icon Composer)" >&2
  exit 1
fi

# render <pixel-size> <output-path> — the default (light) macOS rendition.
render() {
  "$ICTOOL" "$SRC" --export-image --output-file "$2" --platform macOS \
    --rendition Default --width "$1" --height "$1" --scale 1 >/dev/null
}

for sz in 16 32 64 128 256 512 1024; do
  render "$sz" "$APPICONSET/icon_${sz}x${sz}.png"
done

render 512 "$ROOT_DIR/docs/assets/icon.png"
render 512 "$ROOT_DIR/website/assets/icon.png"
render 128 "$ROOT_DIR/website/assets/favicon-128.png"

echo "Rendered icons from $SRC"
