#!/bin/bash
# Render the popover, or the menu bar icon states, to PNG.
#
#   ./preview.sh                 # this Mac's real disks and calendar
#   ./preview.sh demo            # invented data, the bare popover
#   ./preview.sh hero            # the same, open under the menu bar: README
#   ./preview.sh banner          # 1920x1080, for the web.pexelo portfolio
#   ./preview.sh icons           # every menu bar icon state
#   PREVIEW_LANG=sk ./preview.sh demo
#
# MenuBarExtra popovers cannot be opened programmatically, so this is how the
# layout is reviewed. PREVIEW compiles in the demo data, which the app never
# carries. The .lproj folders sit next to the binary because a bare executable
# looks for its resources there; without them every string is the English
# fallback, and plurals come out as "1 hours".
set -euo pipefail
cd "$(dirname "$0")"

OUT="build/preview"
mkdir -p "$OUT"
cp -R Resources/*.lproj "$OUT/"

swiftc -O -swift-version 6 -D PREVIEW -target arm64-apple-macos14.0 \
    Sources/Core/*.swift Sources/App/DesignTokens.swift \
    Sources/App/GuardController.swift Sources/App/MenuContent.swift \
    Sources/App/SettingsView.swift Sources/App/UpdaterProtocol.swift \
    Sources/App/StatusIcon.swift Sources/Preview/main.swift -o "$OUT/preview"

MODE="${1:-}"
case "$MODE" in
    icons) "$OUT/preview" "$OUT/icons.png" icons -AppleLanguages "(${PREVIEW_LANG:-en})" ;;
    demo)  "$OUT/preview" "$OUT/popover.png" demo -AppleLanguages "(${PREVIEW_LANG:-en})" ;;
    banner) "$OUT/preview" "$OUT/banner.png" banner -AppleLanguages "(${PREVIEW_LANG:-en})" ;;
    hero)  "$OUT/preview" "$OUT/hero.png" hero -AppleLanguages "(${PREVIEW_LANG:-en})" ;;
    "")    "$OUT/preview" "$OUT/popover.png" -AppleLanguages "(${PREVIEW_LANG:-en})" ;;
    *)     echo "usage: $0 [demo|hero|banner|icons]" >&2; exit 1 ;;
esac
