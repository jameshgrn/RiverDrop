#!/usr/bin/env bash
# notarize.sh — Build, sign, notarize, and package RiverDrop for direct download.
#
# Prerequisites:
#   1. Developer ID Application certificate installed in Keychain
#      (Xcode > Settings > Accounts > Manage Certificates > "+" > Developer ID Application)
#   2. App Store Connect API key for notarytool:
#      - Create at: developer.apple.com > Users and Access > Integrations > Keys
#      - Download the .p8 file
#      - Set env vars below (or export them before running this script)
#   3. Xcode command-line tools: xcode-select --install
#
# Usage:
#   export TEAM_ID="XXXXXXXXXX"
#   export NOTARY_KEY_ID="YOUR_KEY_ID"
#   export NOTARY_ISSUER_ID="YOUR_ISSUER_UUID"
#   export NOTARY_KEY_PATH="$HOME/.private_keys/AuthKey_YOUR_KEY_ID.p8"
#   ./scripts/notarize.sh

set -euo pipefail

# --- Configuration -----------------------------------------------------------

SCHEME="RiverDrop"
PROJECT="RiverDrop.xcodeproj"
CONFIGURATION="Release"
BUILD_DIR="$(pwd)/build"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="$(pwd)/scripts/ExportOptions.plist"

TEAM_ID="${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to your App Store Connect API key ID}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID to your App Store Connect issuer UUID}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH to the path of your .p8 key file}"

# --- Derived ------------------------------------------------------------------

APP_PATH="${EXPORT_DIR}/${SCHEME}.app"

# --- Helpers ------------------------------------------------------------------

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
fail() {
  printf '\033[1;31mError: %s\033[0m\n' "$1" >&2
  exit 1
}

# --- Preflight ----------------------------------------------------------------

step "Preflight checks"

[[ -f "$NOTARY_KEY_PATH" ]] || fail ".p8 key not found at ${NOTARY_KEY_PATH}"
command -v xcrun >/dev/null || fail "xcrun not found — install Xcode command-line tools"
command -v hdiutil >/dev/null || fail "hdiutil not found"

security find-identity -v -p codesigning | grep -q "Developer ID Application" ||
  fail "No Developer ID Application certificate found in Keychain"

# --- Clean & Archive ---------------------------------------------------------

step "Archiving ${SCHEME} (${CONFIGURATION})"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild clean archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE="Manual" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" |
  tail -1

[[ -d "$ARCHIVE_PATH" ]] || fail "Archive failed — ${ARCHIVE_PATH} not found"

# --- Export -------------------------------------------------------------------

step "Exporting with Developer ID signing"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" |
  tail -1

[[ -d "$APP_PATH" ]] || fail "Export failed — ${APP_PATH} not found"

# Re-derive version now that the app exists
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
DMG_NAME="${SCHEME}-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"

# --- Verify code signature ----------------------------------------------------

step "Verifying code signature"

codesign --verify --deep --strict "$APP_PATH"
echo "Code signature valid."

# --- Create DMG ---------------------------------------------------------------

step "Creating DMG"

DMG_STAGING="${BUILD_DIR}/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "$SCHEME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGING"

# Sign the DMG
codesign --sign "Developer ID Application" --timestamp "$DMG_PATH"

# --- Notarize -----------------------------------------------------------------

step "Submitting to Apple notarization service"

xcrun notarytool submit "$DMG_PATH" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait

# --- Staple -------------------------------------------------------------------

step "Stapling notarization ticket"

xcrun stapler staple "$DMG_PATH"

# --- Final verification -------------------------------------------------------

step "Verifying Gatekeeper acceptance"

spctl --assess --type open --context context:primary-signature "$DMG_PATH" &&
  echo "Gatekeeper: ACCEPTED" ||
  fail "Gatekeeper rejected the DMG"

# --- Summary ------------------------------------------------------------------

SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

step "Done"
echo "DMG:    ${DMG_PATH}"
echo "Size:   $(du -h "$DMG_PATH" | awk '{print $1}')"
echo "SHA256: ${SHA}"
