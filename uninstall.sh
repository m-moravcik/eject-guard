#!/bin/bash
# Stop and remove TM Eject Guard. Config and log are left in place.
set -euo pipefail

osascript -e 'quit app "TM Eject Guard"' 2>/dev/null || true
launchctl bootout "gui/$UID/com.local.tm-eject-guard" 2>/dev/null || true

for path in "/Applications/TM Eject Guard.app" "$HOME/Applications/TM Eject Guard.app" \
            "$HOME/bin/tm-eject-guard" "$HOME/Library/LaunchAgents/com.local.tm-eject-guard.plist"; do
    [ -e "$path" ] && mv "$path" "$HOME/.Trash/" && echo "moved to Trash: $path"
done

echo "config kept at: $HOME/Library/Application Support/TMEjectGuard/config.json"
echo "log kept at:    $HOME/Library/Logs/tm-eject-guard.log"
