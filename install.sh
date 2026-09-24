#!/bin/bash
# Build, install and start Eject Guard.
#
#   ./install.sh              build (ad-hoc signed) and install
#   ./install.sh --no-build   install whatever is already in build/
#
# Use --no-build after release.sh: rebuilding would ad-hoc sign over the
# Developer ID signature and throw away the stapled notarization ticket.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Eject Guard"
# The name before 1.3. Same bundle identifier, so it is the same app and must
# not keep running, or stay installed, next to the renamed one.
LEGACY_APP="TM Eject Guard"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"

if [ "${1:-}" = "--no-build" ]; then
    [ -d "build/$APP_NAME.app" ] || { echo "nothing built yet - run ./build.sh or ./release.sh" >&2; exit 1; }
    echo "using existing build/"
else
    ./build.sh
fi

# An earlier version of this tool ran from a LaunchAgent. Two schedulers would
# race for the same eject, so the agent goes before the app starts.
LEGACY="com.local.tm-eject-guard"
launchctl bootout "gui/$UID/$LEGACY" 2>/dev/null || true
if [ -f "$HOME/Library/LaunchAgents/$LEGACY.plist" ]; then
    mv "$HOME/Library/LaunchAgents/$LEGACY.plist" "$HOME/.Trash/"
    echo "removed legacy LaunchAgent"
fi

# `open` on an app that is already running only activates it, so the old binary
# would keep running and the install would still look like it worked. A menu bar
# accessory does not reliably answer an AppleScript quit either, so make sure it
# is really gone before copying.
# Not `osascript -e 'quit app ...'`: a menu bar accessory does not answer that
# AppleEvent, so osascript sits on its two minute timeout every install.
for name in "$APP_NAME" "$LEGACY_APP"; do
    pkill -f "$name.app/Contents/MacOS/" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -f "$name.app/Contents/MacOS/" >/dev/null || break
        sleep 1
    done
done

mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
for old in "/Applications/$LEGACY_APP.app" "$HOME/Applications/$LEGACY_APP.app" "$HOME/bin/tm-eject-guard"; do
    [ -e "$old" ] && mv "$old" "$HOME/.Trash/" && echo "moved to Trash: $old"
done
# ditto, not cp -R: the bundle embeds Sparkle.framework, which is a tree of
# symlinks into Versions plus four separately signed helpers. ditto is the
# documented way to reproduce that exactly, extended attributes and all.
ditto "build/$APP_NAME.app" "$DEST/$APP_NAME.app"

mkdir -p "$HOME/bin"
cp "build/eject-guard" "$HOME/bin/eject-guard"

open "$DEST/$APP_NAME.app"
sleep 2
pgrep -f "$APP_NAME.app/Contents/MacOS/" >/dev/null \
    || { echo "the app did not start - see ~/Library/Logs/eject-guard.log" >&2; exit 1; }

echo
echo "installed:"
echo "  $DEST/$APP_NAME.app   (menu bar)"
echo "  $HOME/bin/eject-guard  (cli)"
codesign -dv --verbose=2 "$DEST/$APP_NAME.app" 2>&1 | grep -E "^Authority=" | head -1 || true
echo
echo "Next: allow Calendar access when macOS asks, then tick your disk in the"
echo "menu bar popover under DISKS."
