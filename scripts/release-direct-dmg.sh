#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
RUNTIME_APP="$APP_PATH/Contents/Resources/NeAntik Browser.app"
NOTARY_PROFILE="${NEANTIK_NOTARY_PROFILE:-neantik-notary}"
NOTARY_LOG_DIR="$PROJECT_DIR/dist/notary"

fail() {
  echo "DMG release blocked: $*" >&2
  exit 65
}

[[ -d "$APP_PATH" ]] || fail "missing signed app: $APP_PATH"
[[ -f "$INFO_PLIST" ]] || fail "missing app Info.plist"
[[ -d "$RUNTIME_APP" ]] || fail "embedded NeAntik Browser runtime is missing"

VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$INFO_PLIST"
)"
BUILD="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$INFO_PLIST"
)"
[[ -n "$VERSION" && -n "$BUILD" ]] || fail "app version/build is missing"

DMG_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"
[[ ! -e "$DMG_PATH" ]] ||
  fail "final DMG already exists; verify or move it before rebuilding: $DMG_PATH"
[[ ! -e "$CHECKSUM_PATH" ]] ||
  fail "DMG checksum already exists; verify or move it before rebuilding: $CHECKSUM_PATH"

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

DEFAULT_IDENTITY="$(
  print -r -- "$APP_SIGNATURE" |
    sed -n 's/^Authority=//p' |
    grep '^Developer ID Application:' |
    head -n 1
)"
[[ -n "$DEFAULT_IDENTITY" ]] ||
  fail "could not derive the Developer ID Application identity from NeAntik.app"
SIGNING_IDENTITY="$DEFAULT_IDENTITY"

INSTALLED_IDENTITIES="$(security find-identity -v -p codesigning 2>&1)"
if ! print -r -- "$INSTALLED_IDENTITIES" |
  grep -Fq "$SIGNING_IDENTITY"; then
  fail "the app's Developer ID signing identity is not available in this Keychain"
fi

TEMP_ROOT="$(mktemp -d -t neantik-dmg-release)"
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
rm -f "$SUBMIT_LOG"
xcrun notarytool submit \
  "$TEMP_DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait 2>&1 | tee "$SUBMIT_LOG"

NOTARY_STATUS="$(
  awk '/^[[:space:]]*status:/ {print $2}' "$SUBMIT_LOG" |
    tail -n 1
)"
[[ "$NOTARY_STATUS" == "Accepted" ]] ||
  fail "Apple notarization status is ${NOTARY_STATUS:-unknown}; see $SUBMIT_LOG"

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
