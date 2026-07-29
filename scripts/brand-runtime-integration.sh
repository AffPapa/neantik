#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPECTED_VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - \
    "$PROJECT_DIR/runtime/fingerprint-chromium.lock.json"
)"

usage() {
  echo "Usage: $0 /absolute/path/to/Chromium.app /absolute/path/to/NeAntik\\ Browser.app" >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 64
fi

SOURCE_APP="$1"
OUTPUT_APP="$2"

if [[ "$SOURCE_APP" != /* || ! -d "$SOURCE_APP" ]]; then
  echo "Source Chromium.app must be an existing absolute path." >&2
  exit 66
fi
if [[ "$OUTPUT_APP" != /* || "$OUTPUT_APP" != *.app ]]; then
  echo "Output must be an absolute .app path." >&2
  exit 64
fi
if [[ -e "$OUTPUT_APP" ]]; then
  echo "Refusing to replace existing output: $OUTPUT_APP" >&2
  exit 73
fi

SOURCE_PLIST="$SOURCE_APP/Contents/Info.plist"
SOURCE_EXECUTABLE_NAME="$(
  plutil -extract CFBundleExecutable raw -o - "$SOURCE_PLIST" \
    2>/dev/null || true
)"
SOURCE_EXECUTABLE="$SOURCE_APP/Contents/MacOS/$SOURCE_EXECUTABLE_NAME"
if [[ ! -f "$SOURCE_PLIST" || ! -x "$SOURCE_EXECUTABLE" ]]; then
  echo "Source bundle is missing its declared executable or Info.plist." >&2
  exit 66
fi

ACTUAL_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - "$SOURCE_PLIST"
)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Runtime version mismatch." >&2
  echo "Expected: $EXPECTED_VERSION" >&2
  echo "Actual:   $ACTUAL_VERSION" >&2
  exit 65
fi

ditto "$SOURCE_APP" "$OUTPUT_APP"

OUTPUT_PLIST="$OUTPUT_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "NeAntik Browser" "$OUTPUT_PLIST"
plutil -replace CFBundleName -string "NeAntik Browser" "$OUTPUT_PLIST"
plutil -replace CFBundleIdentifier -string "app.neantik.runtime" "$OUTPUT_PLIST"
plutil -replace CFBundleSignature -string "NVsn" "$OUTPUT_PLIST"
if plutil -extract LSApplicationCategoryType raw -o - \
  "$OUTPUT_PLIST" >/dev/null 2>&1; then
  plutil -replace LSApplicationCategoryType \
    -string "public.app-category.utilities" "$OUTPUT_PLIST"
else
  plutil -insert LSApplicationCategoryType \
    -string "public.app-category.utilities" "$OUTPUT_PLIST"
fi
if plutil -extract NeAntikRuntimeFlavor raw -o - \
  "$OUTPUT_PLIST" >/dev/null 2>&1; then
  plutil -replace NeAntikRuntimeFlavor \
    -string "fingerprint-chromium" "$OUTPUT_PLIST"
else
  plutil -insert NeAntikRuntimeFlavor \
    -string "fingerprint-chromium" "$OUTPUT_PLIST"
fi
if plutil -extract NeAntikRuntimeBuildMode raw -o - \
  "$OUTPUT_PLIST" >/dev/null 2>&1; then
  plutil -replace NeAntikRuntimeBuildMode \
    -string "metal-integration" "$OUTPUT_PLIST"
else
  plutil -insert NeAntikRuntimeBuildMode \
    -string "metal-integration" "$OUTPUT_PLIST"
fi

cp "$PROJECT_DIR/Resources/NeAntik.icns" \
  "$OUTPUT_APP/Contents/Resources/app.icns"

codesign --force --deep --sign - "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

echo "Branded NeAntik integration runtime created."
echo "Version: $ACTUAL_VERSION"
echo "Bundle:  app.neantik.runtime"
echo "Output:  $OUTPUT_APP"
