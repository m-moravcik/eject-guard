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

APP_NAME="TM Eject Guard"
APP="build/$APP_NAME.app"
CLI="build/tm-eject-guard"
ZIP="build/$APP_NAME.zip"
ENTITLEMENTS="App/TMEjectGuard.entitlements"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-viberes-notary}"

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
# --options runtime enables the hardened runtime, which notarization requires.
for target in "$CLI" "$APP"; do
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$target"
    echo "signed: $target"
done

step "Verify signature"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|flags"

if [ -n "${SKIP_NOTARIZE:-}" ]; then
    step "Done (notarization skipped)"
    exit 0
fi

step "Notarize"
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
# Plain ./install.sh would rebuild and ad-hoc sign over all of this.
echo "install it with: ./install.sh --no-build"
