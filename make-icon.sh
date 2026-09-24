#!/bin/bash
# Compile App/AppIcon.icon into the files build.sh ships.
#
#   App/AppIcon.icon/     the source: Icon Composer layers (SVG) and icon.json
#   App/Icon/Assets.car   the macOS 26 icon, rendered by the system with glass
#   App/Icon/AppIcon.icns the fallback macOS 14 and 15 read instead
#
# Run it after editing the .icon (in Icon Composer, or by hand) and commit the
# output. It is checked in because actool only understands .icon from Xcode 26
# on, and build.sh - CI included - must not depend on which Xcode is selected.
#
# A plain .icns alone is not enough on macOS 26: Finder shrinks it into a grey
# rounded tile, because only an icon compiled from .icon counts as conforming.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="App/AppIcon.icon"
OUT="App/Icon"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$SOURCE" ] || die "no icon source at $SOURCE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun actool "$SOURCE" --compile "$WORK" \
    --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$WORK/partial.plist" >/dev/null \
    || die "actool failed - it needs Xcode 26 or newer"
[ -f "$WORK/Assets.car" ] && [ -f "$WORK/AppIcon.icns" ] \
    || die "actool produced no icon - is Xcode 26 selected? (xcode-select -p)"

mkdir -p "$OUT"
cp "$WORK/Assets.car" "$WORK/AppIcon.icns" "$OUT/"
echo "wrote $OUT/Assets.car and $OUT/AppIcon.icns"
