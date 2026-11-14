#!/bin/bash
# Build the menu bar app bundle and the CLI.
#
# Output:
#   build/Eject Guard.app                                menu bar app (LSUIElement, no Dock icon)
#   build/Eject Guard.app/Contents/Helpers/eject-guard   command line tool
#
# The CLI ships inside the bundle so it is always the app's version and every
# update replaces both. Helpers rather than MacOS: on a case-insensitive volume
# a lowercase tool next to the app's own executable is one rename from a clash.
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

APP_NAME="Eject Guard"
BUILD="build"
APP="$BUILD/$APP_NAME.app"

sparkle_ensure

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
CLI="$APP/Contents/Helpers/eject-guard"

# ditto rather than cp -R: a framework is a tree of symlinks into Versions, and
# only ditto is guaranteed to reproduce it exactly.
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

echo "building app..."
swiftc -O -warnings-as-errors -swift-version 6 -target arm64-apple-macos14.0 \
    -F "$SPARKLE_ROOT" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/Core/*.swift Sources/Icon/*.swift Sources/App/*.swift \
    -o "$APP/Contents/MacOS/EjectGuard"

cp App/Info.plist "$APP/Contents/Info.plist"
# Compiled by make-icon.sh and checked in, so a build does not depend on which
# Xcode is selected. Assets.car for macOS 26, the .icns for 14 and 15.
cp App/Icon/Assets.car App/Icon/AppIcon.icns "$APP/Contents/Resources/"

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

echo "building cli..."
# The tool has no bundle of its own, so its Info.plist is linked into the
# binary: TCC reads the calendar usage text from it, and --version reads the
# version stamped here, the app's own.
CLI_PLIST="$BUILD/cli-Info.plist"
cp CLI/Info.plist "$CLI_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CLI_PLIST"
# No Sparkle here: Core carries only the updater's pure decision logic.
swiftc -O -warnings-as-errors -swift-version 6 -target arm64-apple-macos14.0 \
    Sources/Core/*.swift Sources/CLI/main.swift \
    -o "$CLI" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$CLI_PLIST"
rm "$CLI_PLIST"

# Innermost first: signing outside-in would seal a hash of contents that are
# about to change.
while IFS= read -r nested; do
    codesign --force --sign - "$nested"
done < <(sparkle_nested_targets "$APP")
codesign --force --sign - --identifier sk.moravcik.tmejectguard.cli "$CLI"
codesign --force --sign - --identifier sk.moravcik.tmejectguard "$APP"

echo "built:"
echo "  $PWD/$APP"
echo "  $PWD/$CLI"
