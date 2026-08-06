#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_APP="$PROJECT_DIR/dist/NeAntik-Integrated.app"
BASE_APP="$PROJECT_DIR/dist/NeAntik.app"

usage() {
  echo "Usage: $0 /absolute/path/to/NeAntik\\ Browser.app /absolute/path/to/args.gn /absolute/path/to/chromium/src /absolute/path/to/runtime-candidate-lock.json" >&2
}

if [[ $# -ne 4 ]]; then
  usage
  exit 64
fi

RUNTIME_APP="$1"
BUILD_ARGS="$2"
SOURCE_ROOT="$3"
CANDIDATE_LOCK="$4"
SOURCE_PROVENANCE="$(dirname "$SOURCE_ROOT")/source-provenance.json"

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
EXPECTED_BUILD_ARGS="$SOURCE_ROOT/out/Default/args.gn"
if [[ "$(cd "$(dirname "$BUILD_ARGS")" && pwd -P)/$(basename "$BUILD_ARGS")" !=
      "$(cd "$(dirname "$EXPECTED_BUILD_ARGS")" && pwd -P)/$(basename "$EXPECTED_BUILD_ARGS")" ]]; then
  echo "args.gn must be the canonical source-root out/Default/args.gn." >&2
  exit 65
fi
EXPECTED_CANDIDATE_LOCK="$(dirname "$SOURCE_ROOT")/runtime-candidate-lock.json"
if [[ "$(cd "$(dirname "$CANDIDATE_LOCK")" && pwd -P)/$(basename "$CANDIDATE_LOCK")" !=
      "$(cd "$(dirname "$EXPECTED_CANDIDATE_LOCK")" && pwd -P)/$(basename "$EXPECTED_CANDIDATE_LOCK")" ]]; then
  echo "Candidate lock must be the one emitted beside source provenance." >&2
  exit 65
fi
if [[ ! -f "$SOURCE_PROVENANCE" || -L "$SOURCE_PROVENANCE" ]]; then
  echo "Chromium source provenance is missing; rebuild/configure the owned Chromium source first." >&2
  exit 66
fi
if [[ "$CANDIDATE_LOCK" != /* ||
      ! -f "$CANDIDATE_LOCK" ||
      -L "$CANDIDATE_LOCK" ]]; then
  echo "Chromium candidate lock must be an absolute regular file." >&2
  exit 66
fi
"$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" \
  "$SOURCE_PROVENANCE" \
  --source-root "$SOURCE_ROOT"
"$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
  "$CANDIDATE_LOCK" \
  "$SOURCE_PROVENANCE"

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
python3 "$PROJECT_DIR/scripts/generate-runtime-integration-notices.py" --check

VERIFY_REPORT="$(mktemp -t nevision-integrated-runtime)"
COMPLIANCE_DIR="$(mktemp -d -t nevision-runtime-compliance)"
SNAPSHOT_ROOT="$(mktemp -d -t nevision-integrated-input)"
SNAPSHOT_RUNTIME="$SNAPSHOT_ROOT/NeAntik Browser.app"
SNAPSHOT_ARGS="$SNAPSHOT_ROOT/args.gn"
PUBLIC_VERIFY_ROOT=""
PUBLIC_VERIFY_APP=""
restore_engineering_bundle() {
  if [[ -n "$PUBLIC_VERIFY_APP" &&
        -d "$PUBLIC_VERIFY_APP" &&
        ! -e "$OUTPUT_APP" ]]; then
    mv "$PUBLIC_VERIFY_APP" "$OUTPUT_APP"
  fi
}
cleanup() {
  restore_engineering_bundle
  rm -f "$VERIFY_REPORT"
  rm -rf "$COMPLIANCE_DIR" "$SNAPSHOT_ROOT"
  if [[ -n "$PUBLIC_VERIFY_ROOT" ]]; then
    rm -rf "$PUBLIC_VERIFY_ROOT"
  fi
}
trap cleanup EXIT
"$PROJECT_DIR/scripts/verify-built-runtime.sh" \
  "$RUNTIME_APP" \
  "$VERIFY_REPORT" \
  "$BUILD_ARGS" \
  "$SOURCE_PROVENANCE" \
  "$CANDIDATE_LOCK"
"$PROJECT_DIR/scripts/generate-runtime-compliance.sh" \
  "$SOURCE_ROOT" \
  "$COMPLIANCE_DIR" \
  "$CANDIDATE_LOCK"
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
cp "$CANDIDATE_LOCK" \
  "$EVIDENCE/fingerprint-chromium.lock.json"
cp "$PROJECT_DIR/runtime/security-baseline.json" \
  "$EVIDENCE/security-baseline.json"
cp "$PROJECT_DIR/runtime/nevision-patches/series.json" \
  "$EVIDENCE/neantik-patch-series.json"
cp "$PROJECT_DIR/runtime/apple-device-tuples.json" \
  "$EVIDENCE/apple-device-tuples.json"
cp "$PROJECT_DIR/runtime/chromium-151-source-contract.json" \
  "$EVIDENCE/chromium-151-source-contract.json"
cp "$SOURCE_PROVENANCE" \
  "$EVIDENCE/source-provenance.json"
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

# The full Direct verifier intentionally accepts only the public bundle name
# NeAntik.app. Move the exact engineering bundle into a private public-name
# verification path, verify it without weakening that gate, then restore the
# engineering artifact for prepare-direct-runtime-candidate.sh.
PUBLIC_VERIFY_ROOT="$(
  /usr/bin/mktemp -d \
    "$PROJECT_DIR/dist/.neantik-integrated-verification.XXXXXX"
)"
PUBLIC_VERIFY_APP="$PUBLIC_VERIFY_ROOT/NeAntik.app"
mv "$OUTPUT_APP" "$PUBLIC_VERIFY_APP"
VERIFY_STATUS=0
"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$PUBLIC_VERIFY_APP" ||
  VERIFY_STATUS=$?
mv "$PUBLIC_VERIFY_APP" "$OUTPUT_APP"
if (( VERIFY_STATUS != 0 )); then
  exit "$VERIFY_STATUS"
fi

echo "$OUTPUT_APP"
