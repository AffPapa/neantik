#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_DIR/dist/NeAntik-Integrated.app}"
if [[ "$APP_PATH" != /* ]]; then
  APP_PARENT="$(cd "$(dirname "$APP_PATH")" && pwd)"
  APP_PATH="$APP_PARENT/$(basename "$APP_PATH")"
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "Integrated NeAntik app does not exist: $APP_PATH" >&2
  exit 66
fi

VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - \
    "$APP_PATH/Contents/Info.plist"
)"
ARGS_GN="$APP_PATH/Contents/Resources/NeAntikRuntimeEvidence/args.gn"
if [[ ! -f "$ARGS_GN" ]]; then
  echo "Integrated app is missing its recorded args.gn." >&2
  exit 66
fi
METAL_TRUE_COUNT="$(
  grep -Ec '^angle_enable_metal[[:space:]]*=[[:space:]]*true$' "$ARGS_GN" ||
    true
)"
METAL_FALSE_COUNT="$(
  grep -Ec '^angle_enable_metal[[:space:]]*=[[:space:]]*false$' "$ARGS_GN" ||
    true
)"
if (( METAL_TRUE_COUNT == 1 && METAL_FALSE_COUNT == 0 )); then
  GPU_MODE="metal"
elif (( METAL_FALSE_COUNT == 1 && METAL_TRUE_COUNT == 0 )); then
  GPU_MODE="no-metal"
else
  echo "Recorded args.gn must explicitly declare angle_enable_metal exactly once." >&2
  exit 65
fi

ARCHIVE_NAME="NeAntik-${VERSION}-arm64-${GPU_MODE}-integrated.zip"
OUTPUT="$PROJECT_DIR/dist/$ARCHIVE_NAME"
TEMP_ROOT="$(mktemp -d -t nevision-integrated-archive)"
ROUNDTRIP_ROOT="$(mktemp -d -t nevision-integrated-roundtrip)"
TEMP_ARCHIVE="$TEMP_ROOT/$ARCHIVE_NAME"
trap 'rm -rf "$TEMP_ROOT" "$ROUNDTRIP_ROOT"' EXIT

"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$APP_PATH"
ditto --norsrc -c -k --keepParent "$APP_PATH" "$TEMP_ARCHIVE"
if unzip -Z1 "$TEMP_ARCHIVE" |
  grep -Eq '(^|/)__MACOSX/|(^|/)\.DS_Store$|(^|/)\._[^/]+$'; then
  echo "Integrated archive contains forbidden Finder metadata." >&2
  exit 65
fi
ditto --norsrc -x -k "$TEMP_ARCHIVE" "$ROUNDTRIP_ROOT"

ROUNDTRIP_APP="$ROUNDTRIP_ROOT/$(basename "$APP_PATH")"
"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$ROUNDTRIP_APP"

mkdir -p "$PROJECT_DIR/dist"
mv "$TEMP_ARCHIVE" "$OUTPUT"

SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
echo "$OUTPUT"
echo "SHA-256: $SHA256"
