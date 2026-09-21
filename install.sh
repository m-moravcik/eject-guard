#!/bin/bash
# Build, install and start TM Eject Guard.
#
#   ./install.sh              build (ad-hoc signed) and install
#   ./install.sh --no-build   install whatever is already in build/
#
# Use --no-build after release.sh: rebuilding would ad-hoc sign over the
# Developer ID signature and throw away the stapled notarization ticket.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TM Eject Guard"
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

osascript -e 'quit app "TM Eject Guard"' 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
cp -R "build/$APP_NAME.app" "$DEST/"

mkdir -p "$HOME/bin"
cp "build/tm-eject-guard" "$HOME/bin/tm-eject-guard"

open "$DEST/$APP_NAME.app"

echo
echo "installed:"
echo "  $DEST/$APP_NAME.app   (menu bar)"
echo "  $HOME/bin/tm-eject-guard  (cli)"
codesign -dv --verbose=2 "$DEST/$APP_NAME.app" 2>&1 | grep -E "^Authority=" | head -1 || true
echo
echo "Next: allow Calendar access when macOS asks, then tick your disk in the"
echo "menu bar popover under DISKS."
