#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="$(
  "$PROJECT_DIR/scripts/resolve-compatible-developer-dir.sh"
)"
APP_DIR="$PROJECT_DIR/dist/NeAntik.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SIGNING_IDENTITY="${NEANTIK_SIGNING_IDENTITY:--}"
DIRECT_ENTITLEMENTS="$PROJECT_DIR/runtime/neantik-direct-entitlements.plist"
BUILD_SUPPORT_DIR="${NEANTIK_BUILD_SUPPORT_DIR:-/private/tmp/nevision-package-direct}"
case "${NEANTIK_WEBKIT_HOST_ENABLED:-0}" in
  0) ;;
  1) echo "WebKit host packaging is not ready: a separately linked runtime host and trusted runtime payload are required" >&2; exit 78 ;;
  *) echo "NEANTIK_WEBKIT_HOST_ENABLED must be 0 or 1" >&2; exit 64 ;;
esac

mkdir -p \
  "$BUILD_SUPPORT_DIR/clang" \
  "$BUILD_SUPPORT_DIR/swiftpm" \
  "$BUILD_SUPPORT_DIR/cache" \
  "$BUILD_SUPPORT_DIR/config" \
  "$BUILD_SUPPORT_DIR/security"
export CLANG_MODULE_CACHE_PATH="$BUILD_SUPPORT_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_SUPPORT_DIR/swiftpm"

cd "$PROJECT_DIR"
swift build \
  --build-system native \
  --jobs 2 \
  -c release \
  --arch arm64 \
  --disable-sandbox \
  --disable-dependency-cache \
  --manifest-cache local \
  --scratch-path "$BUILD_SUPPORT_DIR/build" \
  --cache-path "$BUILD_SUPPORT_DIR/cache" \
  --config-path "$BUILD_SUPPORT_DIR/config" \
  --security-path "$BUILD_SUPPORT_DIR/security"

BIN_PATH="$(
  swift build \
  --build-system native \
    --jobs 2 \
    -c release \
    --arch arm64 \
    --disable-sandbox \
    --disable-dependency-cache \
    --manifest-cache local \
    --scratch-path "$BUILD_SUPPORT_DIR/build" \
    --cache-path "$BUILD_SUPPORT_DIR/cache" \
    --config-path "$BUILD_SUPPORT_DIR/config" \
    --security-path "$BUILD_SUPPORT_DIR/security" \
    --show-bin-path
)"
MANAGER_BINARY="$BIN_PATH/NeAntik"
if [[ ! -x "$MANAGER_BINARY" ]]; then
  echo "Swift release binary is missing: $MANAGER_BINARY" >&2
  exit 70
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$MANAGER_BINARY" "$MACOS_DIR/NeAntik"
python3 "$PROJECT_DIR/scripts/sanitize-manager-rpaths.py" "$MACOS_DIR/NeAntik"
# SwiftPM's release executable can still carry DWARF records with the local
# source and build paths. Remove debug sections before the public signature.
xcrun strip -S "$MACOS_DIR/NeAntik"

cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
python3 "$PROJECT_DIR/scripts/package-update-helpers.py" "$APP_DIR" "$BIN_PATH" "$SIGNING_IDENTITY"
printf 'APPLNANT' >"$CONTENTS_DIR/PkgInfo"
cp "$PROJECT_DIR/Resources/NeAntik.icns" "$RESOURCES_DIR/NeAntik.icns"
cp \
  "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" \
  "$RESOURCES_DIR/PrivacyInfo.xcprivacy"
mkdir -p "$RESOURCES_DIR/ru.lproj"
cp \
  "$PROJECT_DIR/Resources/ru.lproj/InfoPlist.strings" \
  "$PROJECT_DIR/Resources/ru.lproj/Localizable.strings" \
  "$RESOURCES_DIR/ru.lproj/"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  if [[ "${NEANTIK_BROWSER_DATA_BACKUP_ENABLED:-0}" != "0" || -n "${NEANTIK_DIRECT_PROVISIONING_PROFILE:-}" ]]; then
    echo "Engineering signing cannot enable provisioned backup." >&2
    exit 65
  fi
  # Helpers were signed explicitly above. Recursive re-signing would change
  # their CodeDirectory after its pins were sealed into Info.plist.
  codesign --force --sign - "$APP_DIR"
else
  python3 "$PROJECT_DIR/scripts/direct_backup_signing.py" sign "$APP_DIR" "$SIGNING_IDENTITY"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
