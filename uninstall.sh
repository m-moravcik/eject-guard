#!/bin/bash
# Stop and remove Eject Guard, including an install from before the rename.
# Config and log are left in place.
set -euo pipefail
source "$(dirname "$0")/trash.sh"

for name in "Eject Guard" "TM Eject Guard"; do
    pkill -f "$name.app/Contents/MacOS/" 2>/dev/null || true
done
launchctl bootout "gui/$UID/com.local.tm-eject-guard" 2>/dev/null || true

for path in "/Applications/Eject Guard.app" "$HOME/Applications/Eject Guard.app" \
            "/Applications/TM Eject Guard.app" "$HOME/Applications/TM Eject Guard.app" \
            "$HOME/.local/bin/eject-guard" \
            "$HOME/bin/eject-guard" "$HOME/bin/tm-eject-guard" \
            "$HOME/Library/LaunchAgents/com.local.tm-eject-guard.plist"; do
    if [ -e "$path" ]; then
        trash "$path"
        echo "moved to Trash: $path"
    fi
done

echo "config kept at: $HOME/Library/Application Support/EjectGuard/config.json"
echo "log kept at:    $HOME/Library/Logs/eject-guard.log"
