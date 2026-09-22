#!/bin/bash
# Write appcast.xml for a built, signed, notarized archive.
#
#   ./make-appcast.sh build/TM-Eject-Guard-1.1.zip
#
# Run this after release.sh, then attach the same archive to a GitHub release
# tagged v<version> and commit appcast.xml. The feed URL in Info.plist points at
# this file on the main branch, so publishing an update is: release, upload,
# commit.
#
# The archive is signed with the EdDSA key in the login keychain. That key is
# the one thing that cannot be recreated - lose it and no existing install can
# ever be updated again, because they will refuse anything signed by a new key.
# Back it up: bin/generate_keys -x will export it.
set -euo pipefail
cd "$(dirname "$0")"
source ./sparkle.sh

ZIP="${1:-}"
OUT="${2:-appcast.xml}"
REPO="m-moravcik/tm-eject-guard"
APP="build/TM Eject Guard.app"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$ZIP" ] || die "usage: $0 <archive.zip> [appcast.xml]"
[ -f "$ZIP" ] || die "no such archive: $ZIP"
[ -d "$APP" ] || die "no built app at $APP - run ./release.sh first"

sparkle_ensure
SIGN_UPDATE="$SPARKLE_ROOT/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || die "sign_update missing from the Sparkle archive"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }

VERSION="$(plist CFBundleShortVersionString)"
# Sparkle compares sparkle:version, which is CFBundleVersion - the build number,
# not the marketing version. Getting this wrong makes every client see "no
# update" with nothing logged anywhere.
BUILD_NUMBER="$(plist CFBundleVersion)"
MIN_OS="$(plist LSMinimumSystemVersion)"

LENGTH="$(stat -f%z "$ZIP")"
SIGNATURE="$("$SIGN_UPDATE" -p "$ZIP")" || die "sign_update failed"
[ -n "$SIGNATURE" ] || die "sign_update produced no signature"

ASSET="$(basename "$ZIP")"
URL="https://github.com/$REPO/releases/download/v$VERSION/$ASSET"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TM Eject Guard</title>
    <link>https://raw.githubusercontent.com/$REPO/main/appcast.xml</link>
    <description>Ejects external disks before a meeting starts.</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$URL"
                 sparkle:edSignature="$SIGNATURE"
                 length="$LENGTH"
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "wrote $OUT"
echo "  version:   $VERSION ($BUILD_NUMBER)"
echo "  archive:   $ZIP  ($LENGTH bytes)"
echo "  signature: ${SIGNATURE:0:16}…"
echo
echo "next:"
echo "  gh release create v$VERSION \"$ZIP\" --repo $REPO --title \"v$VERSION\" --notes ..."
echo "  git add $OUT && git commit -m \"Release $VERSION\" && git push"
