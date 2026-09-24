#!/bin/bash
# Render App/AppIcon.icns from App/AppIcon.svg.
#
# Run it after editing the SVG and commit both. The .icns is checked in so that
# build.sh needs nothing but the Xcode command line tools.
#
# qlmanage renders SVG through WebKit, which is the renderer that honours the
# drop shadow filter; NSImage's own SVG support silently drops it. Every size is
# downscaled from one 1024 px master rather than rendered separately, which is
# what iconutil expects and keeps the sizes pixel-consistent.
set -euo pipefail
cd "$(dirname "$0")"

SVG="App/AppIcon.svg"
ICNS="App/AppIcon.icns"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
MASTER="$WORK/$(basename "$SVG").png"
[ -f "$MASTER" ] || die "qlmanage did not render $SVG"

ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "wrote $ICNS"
