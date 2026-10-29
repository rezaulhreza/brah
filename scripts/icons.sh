#!/usr/bin/env bash
# Make the app icon and the menu bar icon from the SVG sources in Resources/icon.
# Needs rsvg-convert (brew install librsvg). The results are committed, so a build does not.
#
# App icon: Apple's grid, a 1024 canvas with an 824 tile, every size from 16 to 1024 at @1x
# and @2x, in one .icns. Menu bar icon: an 18 pt template image, 18 px and 36 px.
set -euo pipefail

cd "$(dirname "$0")/../Resources"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" icon/bruh.svg -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" icon/bruh.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o AppIcon.icns

rsvg-convert -w 18 -h 18 icon/menu.svg -o MenuIcon.png
rsvg-convert -w 36 -h 36 icon/menu.svg -o MenuIcon@2x.png

echo "Made Resources/AppIcon.icns, Resources/MenuIcon.png and Resources/MenuIcon@2x.png"
