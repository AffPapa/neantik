#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_DIR/dist/NeAntik.app}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXPECTED_INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/NeAntik"
ICON="$APP_PATH/Contents/Resources/NeAntik.icns"
PRIVACY_MANIFEST="$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy"
PKG_INFO="$APP_PATH/Contents/PkgInfo"

if [[ ! -d "$APP_PATH" || ! -f "$INFO_PLIST" ||
      ! -x "$EXECUTABLE" || ! -f "$ICON" ||
      ! -f "$PRIVACY_MANIFEST" || ! -f "$PKG_INFO" ]]; then
  echo "NeAntik app bundle is incomplete: $APP_PATH" >&2
  exit 66
fi

if [[ "$(cat "$PKG_INFO")" != "APPLNANT" ]]; then
  echo "NeAntik PkgInfo must be APPLNANT." >&2
  exit 65
fi

for key in \
  CFBundleExecutable \
  CFBundleIconFile \
  CFBundleIdentifier \
  CFBundlePackageType \
  CFBundleShortVersionString \
  CFBundleVersion \
  NeAntikDeveloperTeamIdentifier \
  LSMinimumSystemVersion \
  LSRequiresNativeExecution; do
  EXPECTED="$(plutil -extract "$key" raw -o - "$EXPECTED_INFO_PLIST")"
  ACTUAL="$(plutil -extract "$key" raw -o - "$INFO_PLIST")"
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "NeAntik $key does not match project metadata." >&2
    echo "Expected: $EXPECTED" >&2
    echo "Actual:   $ACTUAL" >&2
    exit 65
  fi
done

if ! cmp -s "$PROJECT_DIR/Resources/NeAntik.icns" "$ICON"; then
  echo "NeAntik app icon does not match the project resource." >&2
  exit 65
fi
if ! cmp -s \
  "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" \
  "$PRIVACY_MANIFEST"; then
  echo "NeAntik privacy manifest does not match the project resource." >&2
  exit 65
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ]]; then
  if [[ -e "$APP_PATH/Contents/embedded.provisionprofile" ||
        -L "$APP_PATH/Contents/embedded.provisionprofile" ]]; then
    echo "Local ad-hoc QA must not embed a distribution profile." >&2
    exit 65
  fi
else
  python3 "$PROJECT_DIR/scripts/verify-direct-provisioning-profile.py" \
    --profile "$APP_PATH/Contents/embedded.provisionprofile" \
    --app "$APP_PATH"
fi
"$PROJECT_DIR/scripts/verify-direct-telemetry-disabled.py" \
  --info-plist "$INFO_PLIST"
"$PROJECT_DIR/scripts/verify-direct-update-policy.py" \
  --info-plist "$INFO_PLIST"
"$PROJECT_DIR/scripts/verify-public-fingerprint-corpus.py"
"$PROJECT_DIR/scripts/verify-direct-ui-localization.py"
"$PROJECT_DIR/scripts/verify-direct-branding-residue.py" \
  --app "$APP_PATH" \
  --allow-legacy-runtime-branding

ARCHS="$(lipo -archs "$EXECUTABLE")"
if [[ "$ARCHS" != "arm64" ]]; then
  echo "Expected arm64-only executable, got: $ARCHS" >&2
  exit 65
fi

EXPECTED_MINIMUM_SYSTEM="$(
  plutil -extract LSMinimumSystemVersion raw -o - "$EXPECTED_INFO_PLIST"
)"
BINARY_MINIMUM_SYSTEM="$(
  xcrun vtool -show-build "$EXECUTABLE" |
    awk '/^[[:space:]]*minos[[:space:]]/ { print $2; exit }'
)"
if [[ "$BINARY_MINIMUM_SYSTEM" != "$EXPECTED_MINIMUM_SYSTEM" ]]; then
  echo "NeAntik binary deployment target does not match Info.plist." >&2
  echo "Expected: $EXPECTED_MINIMUM_SYSTEM" >&2
  echo "Actual:   ${BINARY_MINIMUM_SYSTEM:-missing}" >&2
  exit 65
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"

if [[ "$IDENTIFIER" != "app.neantik.desktop" ]]; then
  echo "Unexpected bundle identifier: $IDENTIFIER" >&2
  exit 65
fi

echo "NeAntik $VERSION ($BUILD)"
echo "Bundle: $IDENTIFIER"
echo "Architecture: $ARCHS"

if codesign -d --entitlements - "$APP_PATH" 2>&1 |
    grep -q 'com.apple.security.app-sandbox'; then
  echo "Direct distribution forbids the App Sandbox entitlement." >&2
  exit 65
fi
echo "Distribution: Direct"
