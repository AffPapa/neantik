#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREPARED_APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
PREPARED_INFO_PLIST="$PREPARED_APP_PATH/Contents/Info.plist"

# Only a registered owned location may replace the default candidate paths.
if [[ -n "${NEANTIK_DIRECT_CANDIDATE_ROOT:-}" ]]; then
  CANDIDATE_ROOT="$(python3 -I -B "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
    "$PROJECT_DIR/scripts/release_candidate_location.py" \
    --project-root "$PROJECT_DIR" --validate "$NEANTIK_DIRECT_CANDIDATE_ROOT")"
  PREPARED_APP_PATH="$CANDIDATE_ROOT/NeAntik.app"
  PREPARED_INFO_PLIST="$CANDIDATE_ROOT/NeAntik.app/Contents/Info.plist"
fi

NOTARY_PROFILE="${NEANTIK_NOTARY_PROFILE:-neantik-notary}"
NOTARY_LOG_DIR="$PROJECT_DIR/dist/notary"

fail() {
  echo "DMG release blocked: $*" >&2
  exit 65
}

# Resume bypasses packaging and version-floor checks, but the transaction
# requires the exact source/policy binding and retains all native final gates.
if (( $# > 0 )); then
  [[ $# == 2 && "$1" == "--resume" ]] || fail "usage: $0 [--resume <transaction-root>]"
  RESUME_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
  exec python3 -I -B "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
    "$PROJECT_DIR/scripts/notarize_dmg_transaction.py" \
    --project-root "$PROJECT_DIR" \
    --destination "$PROJECT_DIR/dist/NeAntik-$RESUME_VERSION-arm64-notarized.dmg" \
    --notary-profile "$NOTARY_PROFILE" --resume "$2"
fi

[[ -d "$PREPARED_APP_PATH" ]] ||
  fail "missing signed app: $PREPARED_APP_PATH"
[[ -f "$PREPARED_INFO_PLIST" ]] ||
  fail "missing app Info.plist"

VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PREPARED_INFO_PLIST"
)"
BUILD="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$PREPARED_INFO_PLIST"
)"
[[ -n "$VERSION" && -n "$BUILD" ]] || fail "app version/build is missing"

ZIP_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.zip"
DMG_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

python3 "$PROJECT_DIR/scripts/verify-direct-version-bump.py" --floor-only

[[ -f "$ZIP_PATH" ]] ||
  fail "notarized ZIP is required before DMG creation: $ZIP_PATH"
[[ ! -e "$DMG_PATH" ]] ||
  fail "final DMG already exists; verify or move it before rebuilding: $DMG_PATH"
[[ ! -e "$CHECKSUM_PATH" ]] ||
  fail "DMG checksum already exists; verify or move it before rebuilding: $CHECKSUM_PATH"

# Refuse an earlier retained transaction before extracting/signing another image.
python3 -I -B "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
  "$PROJECT_DIR/scripts/notarize_dmg_transaction.py" \
  --project-root "$PROJECT_DIR" --destination "$DMG_PATH" \
  --notary-profile "$NOTARY_PROFILE" --check-new

python3 "$PROJECT_DIR/scripts/verify-direct-notarized-archive.py" \
  --project-root "$PROJECT_DIR" \
  --archive "$ZIP_PATH"

TEMP_ROOT="$(mktemp -d -t neantik-dmg-release)"
# Canonicalize our own temporary root before the strict app/profile validators.
TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"
ARCHIVE_ROOT="$TEMP_ROOT/archive"
STAGING_DIR="$TEMP_ROOT/staging"
MOUNT_POINT="$TEMP_ROOT/mount"
TEMP_DMG="$TEMP_ROOT/$(basename "$DMG_PATH")"
MOUNTED=0

cleanup() {
  if (( MOUNTED == 1 )); then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$ARCHIVE_ROOT"
ditto -x -k "$ZIP_PATH" "$ARCHIVE_ROOT"
APP_PATH="$ARCHIVE_ROOT/NeAntik.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
RUNTIME_APP="$APP_PATH/Contents/Resources/NeAntik Browser.app"

[[ -d "$APP_PATH" ]] ||
  fail "notarized ZIP does not contain NeAntik.app"
[[ -f "$INFO_PLIST" ]] ||
  fail "notarized ZIP app has no Info.plist"
[[ -d "$RUNTIME_APP" ]] ||
  fail "notarized ZIP app has no embedded NeAntik Browser runtime"
[[ "$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$INFO_PLIST"
)" == "$VERSION" ]] ||
  fail "notarized ZIP app version does not match the prepared candidate"
[[ "$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$INFO_PLIST"
)" == "$BUILD" ]] ||
  fail "notarized ZIP app build does not match the prepared candidate"

APP_SIZE_KB="$(du -sk "$APP_PATH" | awk '{print $1}')"
(( APP_SIZE_KB >= 100000 )) ||
  fail "app is unexpectedly small (${APP_SIZE_KB} KB); refusing to create an empty DMG"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

APP_SIGNATURE="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
if ! print -r -- "$APP_SIGNATURE" |
  grep -q '^Authority=Developer ID Application:'; then
  fail "app is not signed by Developer ID Application"
fi
if ! print -r -- "$APP_SIGNATURE" | grep -q '^Timestamp='; then
  fail "app signature has no trusted timestamp"
fi

CERTIFICATE_PREFIX="$TEMP_ROOT/signing-certificate"
codesign \
  --display \
  --extract-certificates="$CERTIFICATE_PREFIX" \
  "$APP_PATH" >/dev/null 2>&1
LEAF_CERTIFICATE="${CERTIFICATE_PREFIX}0"
[[ -f "$LEAF_CERTIFICATE" ]] ||
  fail "could not extract the Developer ID signing certificate from NeAntik.app"
SIGNING_IDENTITY="$(
  shasum -a 1 "$LEAF_CERTIFICATE" |
    awk '{print toupper($1)}'
)"
print -r -- "$SIGNING_IDENTITY" |
  grep -Eq '^[0-9A-F]{40}$' ||
  fail "the extracted Developer ID signing certificate hash is invalid"

INSTALLED_IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
if ! print -r -- "$INSTALLED_IDENTITIES" |
  awk -v hash="$SIGNING_IDENTITY" '
    $2 == hash && /Developer ID Application:/ { found = 1 }
    END { exit !found }
  '; then
  fail "the app's Developer ID signing identity is not available in this Keychain"
fi

mkdir -p "$STAGING_DIR" "$MOUNT_POINT" "$NOTARY_LOG_DIR"
ditto --norsrc "$APP_PATH" "$STAGING_DIR/NeAntik.app"
ln -s /Applications "$STAGING_DIR/Applications"

[[ -d "$STAGING_DIR/NeAntik.app" ]] ||
  fail "staged app is missing"
[[ -L "$STAGING_DIR/Applications" &&
  "$(readlink "$STAGING_DIR/Applications")" == "/Applications" ]] ||
  fail "Applications shortcut is missing or invalid"

echo "Creating NeAntik $VERSION ($BUILD) DMG from:"
echo "  $APP_PATH"
hdiutil create \
  -volname "NeAntik" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$TEMP_DMG"

DMG_SIZE="$(stat -f '%z' "$TEMP_DMG")"
(( DMG_SIZE >= 50000000 )) ||
  fail "DMG is unexpectedly small (${DMG_SIZE} bytes); refusing notarization"
hdiutil verify "$TEMP_DMG"

codesign \
  --force \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$TEMP_DMG"
codesign --verify --verbose=2 "$TEMP_DMG"
DMG_SIGNATURE="$(codesign --display --verbose=4 "$TEMP_DMG" 2>&1)"
if ! print -r -- "$DMG_SIGNATURE" |
  grep -q '^Authority=Developer ID Application:'; then
  fail "DMG has no usable Developer ID Application signature"
fi
if ! print -r -- "$DMG_SIGNATURE" | grep -q '^Timestamp='; then
  fail "DMG signature has no trusted timestamp"
fi

hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$TEMP_DMG" >/dev/null
MOUNTED=1
[[ -d "$MOUNT_POINT/NeAntik.app" ]] ||
  fail "mounted DMG does not contain NeAntik.app"
[[ -L "$MOUNT_POINT/Applications" &&
  "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] ||
  fail "mounted DMG does not contain the Applications shortcut"
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/NeAntik.app"
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0

# The transaction copies this prepared image to durable private storage before
# contacting Apple. EXIT cleanup may then remove only the disposable staging.
python3 -I -B "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
  "$PROJECT_DIR/scripts/notarize_dmg_transaction.py" \
  --project-root "$PROJECT_DIR" --destination "$DMG_PATH" \
  --notary-profile "$NOTARY_PROFILE" --dmg "$TEMP_DMG" --zip "$ZIP_PATH" \
  --candidate-manifest "$(dirname "$PREPARED_APP_PATH")/direct-candidate-manifest.json"

echo
echo "PASS: signed, notarized and stapled DMG verified."
echo "DMG: $DMG_PATH"
echo "SHA-256: $(awk '{print $1}' "$CHECKSUM_PATH")"
