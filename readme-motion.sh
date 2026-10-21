#!/bin/bash
# The README hero animation: a meeting comes up, the guard stops the backup
# and unmounts the Time Machine disk, the menu bar icon plays its eject
# animation onto the dashed slot, and after the meeting the disk is
# reconnected and backing up again.
#
#   ./readme-motion.sh <output-dir>          # light
#   ./readme-motion.sh <output-dir> dark     # dark
#
# Frames come from the preview harness (./preview.sh motion), rendered
# offscreen from demo data: nothing on this Mac is read, recorded, ejected or
# mounted. Writes hero.gif (960 px, for the README), hero.mp4 (the 2x frames,
# for the web), poster.png (the first frame) and _sheet.png (six key frames).
# Needs ffmpeg.
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:?usage: $0 <output-dir> [dark]}"
SCHEME="${2:-light}"
SUFFIX=""
[ "$SCHEME" = dark ] && SUFFIX="-dark"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

FRAMES="build/preview/motion-$SCHEME"
# Stale frames from a longer take would end up in the loop.
if [ -d "$FRAMES" ]; then
    osascript -e "tell application \"Finder\" to delete POSIX file \"$PWD/$FRAMES\"" >/dev/null
fi
./preview.sh motion "$SCHEME"

FPS=25
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
WIDTH=960
IN=(-framerate "$FPS" -start_number 0 -i "$FRAMES/frame-%04d.png")

# Two-pass palette: one palette for the take, built from what changes.
"$FFMPEG" -v error -y "${IN[@]}" \
    -vf "scale=$WIDTH:-1:flags=lanczos,palettegen=stats_mode=diff" "$FRAMES/palette.png"
"$FFMPEG" -v error -y "${IN[@]}" -i "$FRAMES/palette.png" \
    -lavfi "scale=$WIDTH:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    -loop 0 "$OUT/hero$SUFFIX.gif"

"$FFMPEG" -v error -y "${IN[@]}" -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p \
    -movflags +faststart "$OUT/hero$SUFFIX.mp4"

cp "$FRAMES/frame-0000.png" "$OUT/poster$SUFFIX.png"

# Six beats: backing up before the meeting, ejecting, the icon's launch,
# waiting through the meeting, the slot filling as the disk is back, backing
# up again.
"$FFMPEG" -v error -y "${IN[@]}" \
    -vf "select='eq(n\,0)+eq(n\,45)+eq(n\,87)+eq(n\,135)+eq(n\,182)+eq(n\,228)',scale=600:-1:flags=lanczos,tile=3x2:padding=8:color=white" \
    -frames:v 1 -fps_mode passthrough "$OUT/_sheet$SUFFIX.png"

ls -l "$OUT"
