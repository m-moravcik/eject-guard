#!/bin/bash
# Sign with Developer ID, then notarize and staple.
#
# Why this exists, beyond distribution: an ad-hoc signature is identified by the
# binary's code directory hash, so every rebuild looks like a different program
# to TCC and macOS asks for Calendar access again. A Developer ID signature is a
# stable identity, so the permission is granted once and stays granted.
#
# Notarization is a separate concern - it is what stops Gatekeeper complaining
# on a Mac that did not build the app. Harmless and cheap to do at the same
# time, so this script does both.
#
# Requires a "Developer ID Application" certificate in the keychain, and
# notarization credentials stored as a notarytool keychain profile:
#
#   xcrun notarytool store-credentials <profile> \
#     --key ~/Downloads/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer <uuid>
#
# Environment:
#   SIGN_IDENTITY    Defaults to the Developer ID Application certificate.
#   NOTARY_PROFILE   notarytool keychain profile name.
#   SKIP_NOTARIZE=1  Sign and verify only, no round trip to Apple. Use this to
#                    confirm the certificate resolves before spending a
#                    submission.
#
# Signing needs network access: --timestamp contacts Apple's timestamp
# authority, and a signature without a secure timestamp fails notarization.
set -euo pipefail
cd "$(dirname "$0")"
source ./sparkle.sh

APP_NAME="TM Eject Guard"
APP="build/$APP_NAME.app"
CLI="build/tm-eject-guard"
# Named for the release asset; spaces in a download URL are a nuisance.
ZIP=""  # set once the version is known
ENTITLEMENTS="App/TMEjectGuard.entitlements"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tm-eject-guard-notary}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Preflight"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || die "no Developer ID Application certificate in the keychain"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || die "notarytool profile '$NOTARY_PROFILE' not found. See the header of this script."
fi
echo "identity: $SIGN_IDENTITY"

step "Build"
./build.sh >/dev/null

step "Sign"
# Sparkle's nested helpers first, innermost out. Upstream ships all four ad-hoc
# signed, with no team and no secure timestamp; notarization rejects that.
# No entitlements here: the calendar entitlement belongs to our code, not to a
# downloader and an installer.
while IFS= read -r nested; do
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$nested" \
        || die "failed to sign $nested"
    echo "signed: ${nested#"$PWD/"}"
done < <(sparkle_nested_targets "$APP")

# --options runtime enables the hardened runtime, which notarization requires.
for target in "$CLI" "$APP"; do
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$target"
    echo "signed: $target"
done

step "Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|flags"

# Every signable item, not just the outer bundle. `--verify --deep --strict`
# accepts a valid ad-hoc signature, so it passes here while Apple rejects the
# upload an hour later. Comparing team identifiers is what catches a helper that
# was missed.
#
# The team is read off the app rather than hardcoded, so a fork signing with its
# own certificate is checked just as strictly.
team_of() {
    # Captured into a variable rather than piped into grep: under `pipefail` a
    # `grep -q` that exits on its first match sends SIGPIPE to codesign, and the
    # pipeline then reports a failure that did not happen.
    local info
    info="$(codesign -dv --verbose=4 "$1" 2>&1 || true)"
    printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p'
}

TEAM="$(team_of "$APP")"
[ -n "$TEAM" ] && [ "$TEAM" != "not set" ] \
    || die "the signed app carries no team identifier"

unsigned=0
while IFS= read -r target; do
    if [ "$(team_of "$target")" != "$TEAM" ]; then
        echo "  not signed by $TEAM: ${target#"$PWD/"}" >&2
        unsigned=$((unsigned + 1))
    fi
done < <(sparkle_nested_targets "$APP")
[ "$unsigned" -eq 0 ] || die "$unsigned nested target(s) are not signed by us"
echo "all nested targets carry team identifier $TEAM"

if [ -n "${SKIP_NOTARIZE:-}" ]; then
    step "Done (notarization skipped)"
    exit 0
fi

step "Notarize"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ZIP="build/TM-Eject-Guard-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 60m

step "Staple"
# Stapling attaches the ticket to the bundle so Gatekeeper clears it offline.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

step "Done"
echo "signed, notarized and stapled: $APP"
echo "archive: $ZIP"
echo
echo "publish the update with:"
echo "  ./make-appcast.sh \"$ZIP\""
# Plain ./install.sh would rebuild and ad-hoc sign over all of this.
echo "install it with: ./install.sh --no-build"
