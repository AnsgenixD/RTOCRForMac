#!/bin/bash
#
# build-dmg.sh — local release packaging for MACmort (Overlay).
#
# Builds a Release archive, (optionally) signs + notarizes it, and produces a
# drag-to-Applications DMG. Also used by .github/workflows/release.yml.
#
# Usage:
#   ./scripts/build-dmg.sh                                   # unsigned local build
#   ./scripts/build-dmg.sh --signing-identity "Developer ID Application: YOUR NAME (TEAMID)"
#   ./scripts/build-dmg.sh --signing-identity "Developer ID Application" \
#                          --notary-profile MACMORT_NOTARY_PROFILE \
#                          --output MACmort-v1.0.0.dmg
#
# Notes:
# - Signing requires the Developer ID Application certificate in your keychain
#   (paid Apple Developer Program membership). Notarization additionally
#   requires `xcrun notarytool store-credentials PROFILE` to have been run.
# - Without a signing identity this still produces a DMG, but Gatekeeper will
#   require right-click → Open on other machines.
# - IMPORTANT: Secrets.swift must exist locally (copy secrets.example.swift)
#   or the build will fail — it holds the DeepL key reference.

set -euo pipefail

PROJECT="Overlay.xcodeproj"
SCHEME="Overlay"
CONFIGURATION="Release"
APP_NAME="Overlay"
SIGNING_IDENTITY=""
NOTARY_PROFILE=""
OUTPUT_DMG="MACmort.dmg"
BUILD_DIR="$(mktemp -d)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --signing-identity)  SIGNING_IDENTITY="$2"; shift 2 ;;
        --notary-profile)    NOTARY_PROFILE="$2"; shift 2 ;;
        --output)            OUTPUT_DMG="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."

echo "▸ Building ${CONFIGURATION} archive…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    ${SIGNING_IDENTITY:+CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"} \
    ${SIGNING_IDENTITY:+OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"} \
    build

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/$CONFIGURATION/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || { echo "✗ Built app not found at $APP_PATH" >&2; exit 1; }

if [[ -n "$NOTARY_PROFILE" && -n "$SIGNING_IDENTITY" ]]; then
    echo "▸ Notarizing (profile: $NOTARY_PROFILE)…"
    Ditto_ZIP="$BUILD_DIR/app.zip"
    ditto -c -k --keepParent "$APP_PATH" "$Ditto_ZIP"
    xcrun notarytool submit "$Ditto_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "▸ Stapling…"
    xcrun stapler staple "$APP_PATH"
    spctl -a -vv "$APP_PATH" || true
elif [[ -n "$NOTARY_PROFILE" ]]; then
    echo "⚠ Notary profile given without a signing identity — skipping notarization." >&2
fi

echo "▸ Creating drag-to-Applications DMG…"
STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "MACmort" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$OUTPUT_DMG"

rm -rf "$BUILD_DIR"
echo "✅ Done: $OUTPUT_DMG"
