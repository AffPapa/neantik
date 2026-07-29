#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
EXPECTED_BUILD="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
EXPECTED_NAME="NeAntik-$EXPECTED_VERSION-arm64-notarized.dmg"
DMG_PATH="${1:-$PROJECT_DIR/dist/$EXPECTED_NAME}"

fail() {
  echo "Direct notarized DMG verification failed: $*" >&2
  exit 65
}

[[ "$DMG_PATH" == /* ]] || DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
[[ "$(basename "$DMG_PATH")" == "$EXPECTED_NAME" ]] ||
  fail "image name must be $EXPECTED_NAME"
[[ -f "$DMG_PATH" ]] || fail "image is missing: $DMG_PATH"

CHECKSUM_PATH="$DMG_PATH.sha256"
[[ -f "$CHECKSUM_PATH" ]] ||
  fail "checksum sidecar is missing: $CHECKSUM_PATH"

DMG_SIZE="$(stat -f '%z' "$DMG_PATH")"
(( DMG_SIZE >= 50000000 )) ||
  fail "image is unexpectedly small (${DMG_SIZE} bytes)"

read -r RECORDED_SHA RECORDED_NAME <"$CHECKSUM_PATH"
print -r -- "$RECORDED_SHA" | grep -Eq '^[0-9A-Fa-f]{64}$' ||
  fail "checksum sidecar does not start with a SHA-256"
[[ "$RECORDED_NAME" == "$EXPECTED_NAME" ]] ||
  fail "checksum sidecar must use the basename $EXPECTED_NAME"
ACTUAL_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
[[ "${RECORDED_SHA:l}" == "$ACTUAL_SHA" ]] ||
  fail "checksum mismatch: sidecar=$RECORDED_SHA actual=$ACTUAL_SHA"

hdiutil verify "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
DMG_SIGNATURE="$(codesign --display --verbose=4 "$DMG_PATH" 2>&1)"
print -r -- "$DMG_SIGNATURE" |
  grep -q '^Authority=Developer ID Application:' ||
  fail "image is not signed by Developer ID Application"
print -r -- "$DMG_SIGNATURE" | grep -q '^Timestamp=' ||
  fail "image signature has no trusted timestamp"
xcrun stapler validate "$DMG_PATH"
spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$DMG_PATH"

TEMP_ROOT="$(mktemp -d -t neantik-dmg-verification)"
MOUNT_POINT="$TEMP_ROOT/mount"
MOUNTED=0

cleanup() {
  if (( MOUNTED == 1 )); then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT
mkdir -p "$MOUNT_POINT"

hdiutil attach \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$DMG_PATH" >/dev/null
MOUNTED=1

APP_PATH="$MOUNT_POINT/NeAntik.app"
RUNTIME_APP="$APP_PATH/Contents/Resources/NeAntik Browser.app"
[[ -d "$APP_PATH" ]] || fail "mounted image does not contain NeAntik.app"
[[ -d "$RUNTIME_APP" ]] ||
  fail "mounted NeAntik.app does not contain the embedded browser runtime"
[[ -L "$MOUNT_POINT/Applications" &&
  "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] ||
  fail "mounted image does not contain a valid Applications shortcut"

ACTUAL_VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$APP_PATH/Contents/Info.plist"
)"
ACTUAL_BUILD="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$APP_PATH/Contents/Info.plist"
)"
[[ "$ACTUAL_VERSION" == "$EXPECTED_VERSION" &&
  "$ACTUAL_BUILD" == "$EXPECTED_BUILD" ]] ||
  fail "mounted app version/build is $ACTUAL_VERSION ($ACTUAL_BUILD), expected $EXPECTED_VERSION ($EXPECTED_BUILD)"

"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNTED=0

echo "PASS: Direct notarized DMG verified."
echo "DMG: $DMG_PATH"
echo "Version: $EXPECTED_VERSION ($EXPECTED_BUILD)"
echo "Size: $DMG_SIZE bytes"
echo "SHA-256: $ACTUAL_SHA"
