#!/bin/bash
# Moving to the Trash, sourced by install.sh and uninstall.sh. Nothing a person
# installed is deleted outright: a replaced or removed app, CLI or LaunchAgent
# goes to the Trash, where it can be put back.
#
# TRASH_DIR  Where the Trash is. Only for trying this out; defaults to ~/.Trash.

# mv will not put a bundle where the Trash already holds one of the same name,
# so a second install or uninstall would fail on what the first one left there.
# A name already taken gets the time added before the extension, as Finder
# does, so an app stays an app.
trash() {
    local path="$1" dir="${TRASH_DIR:-$HOME/.Trash}"
    local name base ext stamp target n=2
    name="$(basename "$path")"
    target="$dir/$name"
    if [ -e "$target" ]; then
        case "$name" in
            *.*) base="${name%.*}" ext=".${name##*.}" ;;
            *)   base="$name" ext="" ;;
        esac
        stamp="$(date '+%H.%M.%S')"
        target="$dir/$base $stamp$ext"
        while [ -e "$target" ]; do
            target="$dir/$base $stamp $n$ext"
            n=$((n + 1))
        done
    fi
    mv "$path" "$target"
}
