#!/bin/bash
# Package the transparent keycap at macOS Dock and Finder sizes.
set -euo pipefail
cd "$(dirname "$0")/.."
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
source_icon="assets/icon-master.png"
read -r width height <<< "$(magick identify -format '%w %h' "$source_icon")"
[[ "$width" -eq "$height" && "$width" -ge 1024 ]] || {
    echo "Expected a square icon master at least 1024 pixels wide." >&2
    exit 1
}

if [[ $(magick identify -format '%[opaque]' "$source_icon") == True ]]; then
    echo "Expected transparent pixels around the keycap." >&2
    exit 1
fi
magick "$source_icon" -colorspace sRGB -trim +repage -resize 1008x1008 \
    -gravity center -background none -extent 1024x1024 "$temp/base.png"

iconset="$temp/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    magick "$temp/base.png" -resize "${size}x${size}" "$iconset/icon_${size}x${size}.png"
    doubled=$((size*2))
    magick "$temp/base.png" -resize "${doubled}x${doubled}" "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o assets/AppIcon.icns
