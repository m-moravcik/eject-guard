#!/bin/bash
# Build, install and start TM Eject Guard.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TM Eject Guard"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"

./build.sh

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
echo
echo "Next: allow Calendar access when macOS asks, then pick your disk in the"
echo "menu bar under 'Sledované disky'."
