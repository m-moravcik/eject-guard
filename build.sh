#!/bin/bash
# Build the menu bar app bundle and the CLI.
#
# Output:
#   build/TM Eject Guard.app   menu bar app (LSUIElement, no Dock icon)
#   build/tm-eject-guard       command line tool
#
# Both are ad-hoc signed. TCC identifies an ad-hoc binary by its code directory
# hash, so a rebuild revokes Calendar access and macOS prompts again on the next
# launch. That is expected, and the reason the app is a bundle: a bundle keeps a
# stable identity for everything else the system tracks.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TM Eject Guard"
BUILD="build"
APP="$BUILD/$APP_NAME.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "building app..."
swiftc -O -target arm64-apple-macos14.0 \
    Sources/Core/Guard.swift Sources/App/*.swift \
    -o "$APP/Contents/MacOS/TMEjectGuard"

cp App/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - --identifier sk.moravcik.tmejectguard "$APP"

echo "building cli..."
swiftc -O -target arm64-apple-macos14.0 \
    Sources/Core/Guard.swift Sources/CLI/main.swift \
    -o "$BUILD/tm-eject-guard" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign --force --sign - "$BUILD/tm-eject-guard"

echo "built:"
echo "  $PWD/$APP"
echo "  $PWD/$BUILD/tm-eject-guard"
