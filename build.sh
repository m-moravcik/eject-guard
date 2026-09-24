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
#
# An ad-hoc build also cannot update itself - see UpdaterGate. That is deliberate
# rather than incidental: a development build downloading and running a binary
# from the internet is remote code execution with extra steps.
set -euo pipefail
cd "$(dirname "$0")"
source ./sparkle.sh

APP_NAME="TM Eject Guard"
BUILD="build"
APP="$BUILD/$APP_NAME.app"

sparkle_ensure

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# ditto rather than cp -R: a framework is a tree of symlinks into Versions, and
# only ditto is guaranteed to reproduce it exactly.
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

echo "building app..."
swiftc -O -warnings-as-errors -swift-version 6 -target arm64-apple-macos14.0 \
    -F "$SPARKLE_ROOT" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Core/*.swift Sources/App/*.swift \
    -o "$APP/Contents/MacOS/TMEjectGuard"

cp App/Info.plist "$APP/Contents/Info.plist"
# Checked in, not rendered here, so a build needs no SVG renderer.
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Interface translations. SwiftUI resolves these against the bundle at runtime,
# so a missing .lproj silently falls back to the English in the source; the
# LocalizationTests keep the four in step.
for strings in Resources/*.lproj; do
    [ -d "$strings" ] || continue
    ditto "$strings" "$APP/Contents/Resources/$(basename "$strings")"
done

# Stamp the real version rather than leaving 1.0 in the plist forever: the
# About tab is the only place you can check what is actually installed, and
# Sparkle compares CFBundleVersion to decide whether an update is newer.
VERSION="$(tr -d ' \n' < VERSION)"
# Not BUILD: that already names the output directory further up.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
echo "version: $VERSION ($BUILD_NUMBER)"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Innermost first: signing outside-in would seal a hash of contents that are
# about to change.
while IFS= read -r nested; do
    codesign --force --sign - "$nested"
done < <(sparkle_nested_targets "$APP")
codesign --force --sign - --identifier sk.moravcik.tmejectguard "$APP"

echo "building cli..."
# No Sparkle here. The CLI has no bundle, and Core carries only the updater's
# pure decision logic, never Sparkle itself.
swiftc -O -warnings-as-errors -swift-version 6 -target arm64-apple-macos14.0 \
    Sources/Core/*.swift Sources/CLI/main.swift \
    -o "$BUILD/tm-eject-guard" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker CLI/Info.plist
codesign --force --sign - "$BUILD/tm-eject-guard"

echo "built:"
echo "  $PWD/$APP"
echo "  $PWD/$BUILD/tm-eject-guard"
