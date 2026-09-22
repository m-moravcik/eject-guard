#!/bin/bash
# Shared Sparkle plumbing, sourced by build.sh and release.sh.
#
# The framework is fetched rather than vendored: a 16 MB binary does not belong
# in the history of a source repository, and an updater is the one dependency
# whose compromise means arbitrary code execution, so it is pinned by exact
# version *and* by checksum. A new version is a deliberate edit here, never a
# silent "latest".

SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_ROOT=".build/sparkle/$SPARKLE_VERSION"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.framework"

sparkle_die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Download and unpack once, into a gitignored cache keyed by version.
sparkle_ensure() {
    [ -d "$SPARKLE_FRAMEWORK" ] && return 0

    echo "fetching Sparkle $SPARKLE_VERSION..."
    mkdir -p "$SPARKLE_ROOT"
    local tarball="$SPARKLE_ROOT/Sparkle.tar.xz"
    curl -fsSL --retry 3 -o "$tarball" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        || sparkle_die "could not download Sparkle $SPARKLE_VERSION"

    local actual
    actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    if [ "$actual" != "$SPARKLE_SHA256" ]; then
        rm -f "$tarball"
        sparkle_die "Sparkle checksum mismatch
  expected $SPARKLE_SHA256
  got      $actual"
    fi

    tar -xJf "$tarball" -C "$SPARKLE_ROOT" \
        || sparkle_die "could not unpack Sparkle"
    [ -d "$SPARKLE_FRAMEWORK" ] \
        || sparkle_die "Sparkle archive did not contain Sparkle.framework"
}

# Every nested item inside an embedded Sparkle.framework that has to be signed
# in its own right, innermost first.
#
# Upstream ships all four ad-hoc signed, with no team and no secure timestamp.
# Notarization rejects that, and `codesign --verify --deep --strict` does not
# catch it, because a valid ad-hoc signature is still a valid signature. Signing
# outside-in would seal a hash of contents that are about to change, so order
# here is load bearing.
sparkle_nested_targets() {
    local app="$1"
    local framework="$app/Contents/Frameworks/Sparkle.framework"
    [ -d "$framework" ] || return 0

    # Resolve through Versions/Current rather than hardcoding a letter, and
    # refuse anything that resolves outside the framework.
    local versions current
    versions="$framework/Versions"
    current="$(cd "$versions/Current" 2>/dev/null && pwd -P || true)"
    [ -n "$current" ] || sparkle_die "cannot resolve $versions/Current"
    case "$current" in
        "$(cd "$versions" && pwd -P)"/*) : ;;
        *) sparkle_die "Sparkle version directory resolves outside the framework: $current" ;;
    esac

    local nested
    for nested in \
        "$current/XPCServices/Downloader.xpc" \
        "$current/XPCServices/Installer.xpc" \
        "$current/Autoupdate" \
        "$current/Updater.app" \
        "$current"
    do
        [ -e "$nested" ] && printf '%s\n' "$nested"
    done
}
