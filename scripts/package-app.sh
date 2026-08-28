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
BUILD_SUPPORT_DIR="${NEANTIK_BUILD_SUPPORT_DIR:-/private/tmp/nevision-package-direct}"

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
  -c release \
  --arch arm64 \
  --disable-sandbox \
  --cache-path "$BUILD_SUPPORT_DIR/cache" \
  --config-path "$BUILD_SUPPORT_DIR/config" \
  --security-path "$BUILD_SUPPORT_DIR/security"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_DIR/.build/arm64-apple-macosx/release/NeAntik" "$MACOS_DIR/NeAntik"

cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
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
  codesign --force --deep --sign - "$APP_DIR"
else
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
