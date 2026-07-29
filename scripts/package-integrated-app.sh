#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_APP="$PROJECT_DIR/dist/NeAntik-Integrated.app"
BASE_APP="$PROJECT_DIR/dist/NeAntik.app"

usage() {
  echo "Usage: $0 /absolute/path/to/NeAntik\\ Browser.app /absolute/path/to/args.gn /absolute/path/to/chromium/src" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

RUNTIME_APP="$1"
BUILD_ARGS="$2"
SOURCE_ROOT="$3"

if [[ "$RUNTIME_APP" != /* || ! -d "$RUNTIME_APP" ]]; then
  echo "NeAntik Browser.app must be an existing absolute path." >&2
  exit 66
fi
if [[ "$BUILD_ARGS" != /* || ! -f "$BUILD_ARGS" ]]; then
  echo "args.gn must be an existing absolute path." >&2
  exit 66
fi
if [[ "$SOURCE_ROOT" != /* || ! -d "$SOURCE_ROOT" ]]; then
  echo "Chromium source root must be an existing absolute path." >&2
  exit 66
fi

RUNTIME_PLIST="$RUNTIME_APP/Contents/Info.plist"
RUNTIME_BUNDLE_ID="$(
  plutil -extract CFBundleIdentifier raw -o - "$RUNTIME_PLIST"
)"
RUNTIME_FLAVOR="$(
  plutil -extract NeAntikRuntimeFlavor raw -o - "$RUNTIME_PLIST"
)"
if [[ "$RUNTIME_BUNDLE_ID" != "app.neantik.runtime" ||
      "$RUNTIME_FLAVOR" != "fingerprint-chromium" ]]; then
  echo "Runtime is not a declared NeAntik fingerprint runtime." >&2
  exit 65
fi

VERIFY_REPORT="$(mktemp -t nevision-integrated-runtime)"
COMPLIANCE_DIR="$(mktemp -d -t nevision-runtime-compliance)"
SNAPSHOT_ROOT="$(mktemp -d -t nevision-integrated-input)"
SNAPSHOT_RUNTIME="$SNAPSHOT_ROOT/NeAntik Browser.app"
SNAPSHOT_ARGS="$SNAPSHOT_ROOT/args.gn"
trap 'rm -f "$VERIFY_REPORT"; rm -rf "$COMPLIANCE_DIR" "$SNAPSHOT_ROOT"' EXIT
"$PROJECT_DIR/scripts/verify-built-runtime.sh" \
  "$RUNTIME_APP" \
  "$VERIFY_REPORT" \
  "$BUILD_ARGS"
"$PROJECT_DIR/scripts/generate-runtime-compliance.sh" \
  "$SOURCE_ROOT" \
  "$COMPLIANCE_DIR"
ditto "$RUNTIME_APP" "$SNAPSHOT_RUNTIME"
cp "$BUILD_ARGS" "$SNAPSHOT_ARGS"

NEANTIK_SIGNING_IDENTITY=- "$PROJECT_DIR/scripts/package-app.sh"

rm -rf "$OUTPUT_APP"
ditto "$BASE_APP" "$OUTPUT_APP"

RESOURCES="$OUTPUT_APP/Contents/Resources"
EVIDENCE="$RESOURCES/NeAntikRuntimeEvidence"
LICENSES="$RESOURCES/NeAntikRuntimeLicenses"
COMPLIANCE="$RESOURCES/NeAntikRuntimeCompliance"
mkdir -p "$EVIDENCE" "$LICENSES"

ditto "$SNAPSHOT_RUNTIME" "$RESOURCES/NeAntik Browser.app"
cp "$PROJECT_DIR/runtime/fingerprint-chromium.lock.json" \
  "$EVIDENCE/fingerprint-chromium.lock.json"
cp "$PROJECT_DIR/runtime/security-baseline.json" \
  "$EVIDENCE/security-baseline.json"
cp "$PROJECT_DIR/runtime/nevision-patches/series.json" \
  "$EVIDENCE/neantik-patch-series.json"
cp "$PROJECT_DIR/runtime/apple-device-tuples.json" \
  "$EVIDENCE/apple-device-tuples.json"
cp "$SNAPSHOT_ARGS" "$EVIDENCE/args.gn"
cp "$VERIFY_REPORT" "$EVIDENCE/runtime-verification.json"
cp "$PROJECT_DIR/docs/RUNTIME_INTEGRATION_NOTICES.md" \
  "$RESOURCES/NeAntikRuntimeNotices.md"
ditto "$COMPLIANCE_DIR" "$COMPLIANCE"

cp "$PROJECT_DIR/runtime/licenses/Chromium-LICENSE" \
  "$LICENSES/Chromium-LICENSE"
cp "$PROJECT_DIR/runtime/licenses/fingerprint-chromium-LICENSE" \
  "$LICENSES/fingerprint-chromium-LICENSE"
cp "$PROJECT_DIR/runtime/licenses/ungoogled-chromium-macos-LICENSE" \
  "$LICENSES/ungoogled-chromium-macos-LICENSE"

codesign --force --sign - "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$OUTPUT_APP"
echo "$OUTPUT_APP"
