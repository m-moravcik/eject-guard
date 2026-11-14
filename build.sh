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
# -P: the compiler records sources by their real path, and the metadata
# processor below matches the absolute paths built from $PWD against them, so
# a checkout reached through a symlink (/tmp is one) would match nothing.
cd -P "$(dirname "$0")"
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
APP_SOURCES=(Sources/Core/*.swift Sources/Icon/*.swift Sources/App/*.swift)
INTENTS="$BUILD/intents"
mkdir -p "$INTENTS"
# Shortcuts finds the app's actions in Metadata.appintents, which Xcode writes
# with appintentsmetadataprocessor from the compiler's const values. Without an
# Xcode project, the same two steps run here: the compiler records the values
# of every type conforming to the App Intents protocols below, and the
# processor turns them into the metadata. Without it the actions compile and
# never appear.
printf '%s' '["AppIntent","AppEntity","TransientEntity","AppEnum","EntityQuery","AppShortcutsProvider","AppShortcutProviding","DynamicOptionsProvider","AppIntentsPackage","AnyResolverProviding","_IntentValueRepresentable"]' \
    > "$INTENTS/protocols.json"
swiftc -O -wmo -warnings-as-errors -swift-version 6 -target arm64-apple-macos14.0 \
    -module-name EjectGuard \
    -F "$SPARKLE_ROOT" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -emit-const-values -emit-const-values-path "$INTENTS/EjectGuard.swiftconstvalues" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS/protocols.json" \
    "${APP_SOURCES[@]}" \
    -o "$APP/Contents/MacOS/EjectGuard"

printf "$PWD/%s\n" "${APP_SOURCES[@]}" > "$INTENTS/sources.txt"
echo "$PWD/$INTENTS/EjectGuard.swiftconstvalues" > "$INTENTS/constvalues.txt"
xcrun appintentsmetadataprocessor \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(xcrun --find swiftc)")")" \
    --module-name EjectGuard \
    --sdk-root "$(xcrun --show-sdk-path --sdk macosx)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
    --source-file-list "$INTENTS/sources.txt" \
    --swift-const-vals-list "$INTENTS/constvalues.txt" \
    --binary-file "$APP/Contents/MacOS/EjectGuard" \
    --quiet-warnings > "$INTENTS/processor.log" 2>&1 \
    || { cat "$INTENTS/processor.log" >&2; exit 1; }
# A processor that ran but dropped an action, for one with a parameter that is
# not a literal, would ship an app without it.
for intent in EjectNowIntent PauseGuardIntent ResumeGuardIntent SkipNextMeetingIntent StopBackupIntent; do
    grep -q "\"$intent\"" "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" \
        || { echo "Metadata.appintents is missing $intent" >&2; exit 1; }
done
rm -rf "$INTENTS"

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
# About tab and `eject-guard --version` are where you check what is installed, and
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
