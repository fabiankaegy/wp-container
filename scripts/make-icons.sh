#!/usr/bin/env bash
#
# make-icons.sh — regenerate WPContainer/Assets.xcassets/AppIcon.appiconset from
# docs/assets/icon-source.png.
#
# The source render is a ~1254x1254 image of a blue squircle (WordPress "W"
# logo, blueprint grid) centered on an OPAQUE light-gray background with
# margins. This script:
#   1. Locates the squircle's true content bounding box inside the source
#      (the background is a near-uniform light gray; the squircle is blue).
#   2. Crops + uniformly scales (no stretching) the content so the squircle
#      occupies the Apple macOS icon grid proportion: 824/1024 with a ~100px
#      transparent margin on the larger axis, centered on a transparent
#      1024x1024 canvas.
#   3. Masks everything outside the squircle's own rounded-corner silhouette
#      to fully transparent, using a superellipse ("continuous corner")
#      matching the artwork's measured corner curve, so no gray slivers or
#      shadow bleed survive in the corners.
#   4. Renders the full standard set of macOS icon sizes with `sips` and
#      writes Contents.json for the .appiconset.
#
# Requirements: ImageMagick (`magick`), `sips`, `python3` (stdlib only).
#
# If a better/updated render is produced later, drop it in at
# docs/assets/icon-source.png and re-run this script. Note: the crop/scale/
# mask parameters below were measured from the current source render. If the
# new render has different margins or a different corner radius, re-measure
# (see docs/assets/ICON-MEASUREMENTS.txt if present, or re-derive by scanning
# for the gray/blue boundary) and update the constants below.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT_DIR/docs/assets/icon-source.png}"
APPICONSET="$ROOT_DIR/WPContainer/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! command -v magick >/dev/null 2>&1; then
  echo "error: ImageMagick ('magick') is required but not found in PATH" >&2
  exit 1
fi
if ! command -v sips >/dev/null 2>&1; then
  echo "error: 'sips' is required but not found in PATH" >&2
  exit 1
fi
if [[ ! -f "$SRC" ]]; then
  echo "error: source image not found: $SRC" >&2
  exit 1
fi

echo "==> Source: $SRC"
echo "==> Work dir: $WORK"

# --- Measured constants for the current icon-source.png (1254x1254) -------
# Squircle true content edges (sub-pixel, blue-vs-background boundary):
#   left=112.5 top=87.5 right=1140.5 bottom=1138.5  (w=1028 h=1051)
# Corner radius ratio ≈ 22.4% of squircle width (matches Apple's ~824/1024
# canonical macOS icon grid, corner radius ≈185px @ 1024 canvas).
CROP_L=106
CROP_T=81
CROP_R=1147
CROP_B=1145
TRUE_L=112.5
TRUE_T=87.5
TRUE_R=1140.5
TRUE_B=1138.5
SUPERELLIPSE_N=5
CANVAS=1024
SQUIRCLE=824
MARGIN=$(( (CANVAS - SQUIRCLE) / 2 ))

CROP_W=$((CROP_R - CROP_L))
CROP_H=$((CROP_B - CROP_T))

echo "==> Cropping content bounds ${CROP_W}x${CROP_H}+${CROP_L}+${CROP_T}"
magick "$SRC" -crop "${CROP_W}x${CROP_H}+${CROP_L}+${CROP_T}" +repage "$WORK/crop.png"

# Compute uniform scale + placement so the true squircle content maps to an
# SQUIRCLE x SQUIRCLE box centered on the CANVAS x CANVAS transparent canvas,
# without distorting the artwork (scale factor derived from the LARGER true
# dimension so nothing is ever clipped).
read -r SCALE NEW_CROP_W NEW_CROP_H OFFSET_X OFFSET_Y <<EOF
$(python3 - "$CROP_L" "$CROP_T" "$CROP_W" "$CROP_H" "$TRUE_L" "$TRUE_T" "$TRUE_R" "$TRUE_B" "$SQUIRCLE" "$MARGIN" <<'PY'
import sys
crop_l, crop_t, crop_w, crop_h, tl, tt, tr, tb, squircle, margin = map(float, sys.argv[1:11])
true_w = tr - tl
true_h = tb - tt
scale = squircle / max(true_w, true_h)
new_crop_w = crop_w * scale
new_crop_h = crop_h * scale
tl_in_crop = (tl - crop_l) * scale
tt_in_crop = (tt - crop_t) * scale
offset_x = margin - tl_in_crop
offset_y = margin - tt_in_crop
print(f"{scale:.6f} {round(new_crop_w)} {round(new_crop_h)} {round(offset_x)} {round(offset_y)}")
PY
)
EOF

echo "==> Scale=$SCALE  scaled crop=${NEW_CROP_W}x${NEW_CROP_H}  offset=+${OFFSET_X}+${OFFSET_Y}"
magick "$WORK/crop.png" -filter Lanczos -resize "${NEW_CROP_W}x${NEW_CROP_H}!" "$WORK/crop_scaled.png"

magick -size "${CANVAS}x${CANVAS}" xc:none "$WORK/crop_scaled.png" \
  -geometry "+${OFFSET_X}+${OFFSET_Y}" -compose Over -composite "$WORK/composited.png"

# Flatten to opaque RGB (removes any partial edge transparency from the
# paste) before applying our own precise alpha mask.
magick "$WORK/composited.png" -background white -alpha remove -alpha off "$WORK/composited_rgb.png"

# Build a superellipse ("continuous corner") alpha mask at 4x supersampling
# for clean antialiasing, matching the SQUIRCLE x SQUIRCLE region centered
# on the CANVAS x CANVAS transparent frame.
SS=4
SS_CANVAS=$((CANVAS * SS))
SS_CENTER=$((SS_CANVAS / 2))
SS_HALF=$(( (SQUIRCLE * SS) / 2 ))
echo "==> Building superellipse mask (n=${SUPERELLIPSE_N}) at ${SS_CANVAS}x${SS_CANVAS} supersample"
magick -size "${SS_CANVAS}x${SS_CANVAS}" xc:black -fx \
  "((abs((i-${SS_CENTER})/${SS_HALF}))^${SUPERELLIPSE_N}+(abs((j-${SS_CENTER})/${SS_HALF}))^${SUPERELLIPSE_N})<=1 ? 1 : 0" \
  -colorspace Gray "$WORK/mask_super.png"
magick "$WORK/mask_super.png" -filter Lanczos -resize "${CANVAS}x${CANVAS}" "$WORK/mask.png"

magick "$WORK/composited_rgb.png" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite "$WORK/icon_1024.png"

echo "==> Canonical 1024x1024 icon: $WORK/icon_1024.png"

mkdir -p "$APPICONSET"
CANON="$WORK/icon_1024.png"

declare -a SIZES=(16 32 64 128 256 512 1024)
for sz in "${SIZES[@]}"; do
  out="$APPICONSET/icon_${sz}x${sz}.png"
  sips -z "$sz" "$sz" "$CANON" --out "$out" >/dev/null
  echo "==> wrote $out"
done

cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32", "filename" : "icon_64x64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024x1024.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

echo "==> wrote $APPICONSET/Contents.json"

# --- Menu bar template icon (PLAN.md §2h) ---------------------------------
# Extract the white W-in-circle mark from the canonical icon into a black +
# alpha TEMPLATE image (Render As: Template) at 18pt and 36pt (@2x) so the menu
# bar status item renders monochrome and adapts to light/dark menu bars and
# accent tints like every other status item.
echo "==> Generating menu bar template icon"
MBSET="$ROOT_DIR/WPContainer/Assets.xcassets/MenuBarIcon.imageset"
mkdir -p "$MBSET"
# 1. Near-white mark region on the icon flattened against its blue squircle.
magick "$CANON" -alpha off -colorspace Gray -threshold 72% "$WORK/mb_bright.png"
# 2. Opacity mask (inside the squircle only).
magick "$CANON" -alpha extract "$WORK/mb_opaque.png"
# 3. Mark = bright AND opaque (drops the blue field between ring and W).
magick "$WORK/mb_bright.png" "$WORK/mb_opaque.png" -compose Multiply -composite "$WORK/mb_markmask.png"
# 4. Keep only the central mark, dropping the artwork's faint corner grid marks
#    (a centered disc of radius ~340/1024 contains the mark, excludes corners).
magick -size 1024x1024 xc:black -fill white -draw "circle 512,512 512,172" "$WORK/mb_region.png"
magick "$WORK/mb_markmask.png" "$WORK/mb_region.png" -compose Multiply -composite -threshold 50% "$WORK/mb_mask.png"
# 5. Black shape with alpha = mark mask, trimmed to the mark's bounds.
magick -size 1024x1024 xc:black "$WORK/mb_mask.png" -alpha off -compose CopyOpacity -composite -trim +repage "$WORK/mb_mark.png"
# 6. 18pt (@1x) and 36pt (@2x): the circle mark fills ~16/32 px, centered.
magick "$WORK/mb_mark.png" -filter Lanczos -resize 16x16 -background none -gravity center -extent 18x18 "$MBSET/MenuBarIcon.png"
magick "$WORK/mb_mark.png" -filter Lanczos -resize 32x32 -background none -gravity center -extent 36x36 "$MBSET/MenuBarIcon@2x.png"
cat > "$MBSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "universal", "filename" : "MenuBarIcon.png", "scale" : "1x" },
    { "idiom" : "universal", "filename" : "MenuBarIcon@2x.png", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
echo "==> wrote $MBSET"
echo "==> done."
