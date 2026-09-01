#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREPARED_APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
PREPARED_INFO_PLIST="$PREPARED_APP_PATH/Contents/Info.plist"
NOTARY_PROFILE="${NEANTIK_NOTARY_PROFILE:-neantik-notary}"
NOTARY_LOG_DIR="$PROJECT_DIR/dist/notary"
NOTARY_KEYCHAIN_ARGUMENTS=()

fail() {
  echo "DMG release blocked: $*" >&2
  exit 65
}

if [[ -n "${NEANTIK_NOTARY_KEYCHAIN:-}" ]]; then
  NOTARY_KEYCHAIN="$NEANTIK_NOTARY_KEYCHAIN"
  [[ "$NOTARY_KEYCHAIN" == /* && -f "$NOTARY_KEYCHAIN" && ! -L "$NOTARY_KEYCHAIN" ]] ||
    fail "explicit notary Keychain must be one absolute regular file"
  [[ "$(stat -f '%u' "$NOTARY_KEYCHAIN")" == "$EUID" ]] ||
    fail "explicit notary Keychain must be owned by the current user"
  [[ "$(stat -f '%l' "$NOTARY_KEYCHAIN")" == "1" ]] ||
    fail "explicit notary Keychain must have one hard link"
  NOTARY_KEYCHAIN_MODE="$(stat -f '%Lp' "$NOTARY_KEYCHAIN")"
  (( (8#$NOTARY_KEYCHAIN_MODE & 077) == 0 )) ||
    fail "explicit notary Keychain must be owner-only"
  NOTARY_KEYCHAIN_ARGUMENTS=(--keychain "$NOTARY_KEYCHAIN")
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
[[ -f "$ZIP_PATH" ]] ||
  fail "notarized ZIP is required before DMG creation: $ZIP_PATH"
[[ ! -e "$DMG_PATH" ]] ||
  fail "final DMG already exists; verify or move it before rebuilding: $DMG_PATH"
[[ ! -e "$CHECKSUM_PATH" ]] ||
  fail "DMG checksum already exists; verify or move it before rebuilding: $CHECKSUM_PATH"

python3 "$PROJECT_DIR/scripts/verify-direct-notarized-archive.py" \
  --project-root "$PROJECT_DIR" \
  --archive "$ZIP_PATH"

TEMP_ROOT="$(mktemp -d -t neantik-dmg-release)"
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

SUBMIT_LOG="$NOTARY_LOG_DIR/$(basename "$DMG_PATH").notary-submit.log"
NOTARY_RECEIPT="$NOTARY_LOG_DIR/$(basename "$DMG_PATH").notary-receipt.json"
rm -f "$SUBMIT_LOG"
rm -f "$NOTARY_RECEIPT"
xcrun notarytool submit \
  "$TEMP_DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  "${NOTARY_KEYCHAIN_ARGUMENTS[@]}" \
  --wait \
  --output-format json |
  tee "$SUBMIT_LOG"

read -r SUBMISSION_ID NOTARY_STATUS <<<"$(
  python3 - "$SUBMIT_LOG" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
submission_id = payload.get("id")
status = payload.get("status")
if not isinstance(submission_id, str) or not submission_id.strip():
    raise SystemExit("notary submission JSON has no id")
if status not in {"Accepted", "Invalid", "In Progress", "Rejected"}:
    raise SystemExit("notary submission JSON has an invalid status")
print(submission_id, status)
PY
)"
[[ "$NOTARY_STATUS" == "Accepted" ]] ||
  fail "Apple notarization status is ${NOTARY_STATUS:-unknown}; see $SUBMIT_LOG"
xcrun notarytool log \
  "$SUBMISSION_ID" \
  --keychain-profile "$NOTARY_PROFILE" \
  "${NOTARY_KEYCHAIN_ARGUMENTS[@]}" \
  "$NOTARY_RECEIPT"
python3 -m json.tool "$NOTARY_RECEIPT" >/dev/null

xcrun stapler staple "$TEMP_DMG"
xcrun stapler validate "$TEMP_DMG"
codesign --verify --verbose=2 "$TEMP_DMG"
DMG_SIGNATURE="$(codesign --display --verbose=4 "$TEMP_DMG" 2>&1)"
print -r -- "$DMG_SIGNATURE" |
  grep -q '^Authority=Developer ID Application:' ||
  fail "stapled DMG lost its Developer ID Application signature"
print -r -- "$DMG_SIGNATURE" | grep -q '^Timestamp=' ||
  fail "stapled DMG signature has no trusted timestamp"
spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$TEMP_DMG"
hdiutil verify "$TEMP_DMG"

hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$TEMP_DMG" >/dev/null
MOUNTED=1
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/NeAntik.app"
xcrun stapler validate "$MOUNT_POINT/NeAntik.app"
spctl --assess --type execute --verbose=4 "$MOUNT_POINT/NeAntik.app"
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0

(
  cd "$(dirname "$TEMP_DMG")"
  shasum -a 256 "$(basename "$TEMP_DMG")"
) >"$TEMP_DMG.sha256"
"$PROJECT_DIR/scripts/verify-direct-notarized-dmg.sh" "$TEMP_DMG"

mv "$TEMP_DMG" "$DMG_PATH"
mv "$TEMP_DMG.sha256" "$CHECKSUM_PATH"

echo
echo "PASS: signed, notarized and stapled DMG verified."
echo "DMG: $DMG_PATH"
echo "SHA-256: $(awk '{print $1}' "$CHECKSUM_PATH")"
echo "Notary log: $SUBMIT_LOG"
