#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_DIR/dist/NeAntik-Integrated.app}"
if [[ "$APP_PATH" != /* ]]; then
  APP_PARENT="$(cd "$(dirname "$APP_PATH")" && pwd)"
  APP_PATH="$APP_PARENT/$(basename "$APP_PATH")"
fi
MANAGER_EXECUTABLE="$APP_PATH/Contents/MacOS/NeAntik"
RUNTIME_APP="$APP_PATH/Contents/Resources/NeAntik Browser.app"
EVIDENCE="$APP_PATH/Contents/Resources/NeAntikRuntimeEvidence"
LICENSES="$APP_PATH/Contents/Resources/NeAntikRuntimeLicenses"
COMPLIANCE="$APP_PATH/Contents/Resources/NeAntikRuntimeCompliance"
REPORT="$(mktemp -t nevision-integrated-verification)"
trap 'rm -f "$REPORT"' EXIT

EXPECTED_MANAGER_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - \
    "$PROJECT_DIR/Resources/Info.plist"
)"
EXPECTED_MANAGER_BUILD="$(
  plutil -extract CFBundleVersion raw -o - \
    "$PROJECT_DIR/Resources/Info.plist"
)"
ACTUAL_MANAGER_VERSION="$(
  plutil -extract CFBundleShortVersionString raw -o - \
    "$APP_PATH/Contents/Info.plist"
)"
ACTUAL_MANAGER_BUILD="$(
  plutil -extract CFBundleVersion raw -o - \
    "$APP_PATH/Contents/Info.plist"
)"
EXPECTED_RUNTIME_VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - \
    "$PROJECT_DIR/runtime/fingerprint-chromium.lock.json"
)"
if [[ "$ACTUAL_MANAGER_VERSION" != "$EXPECTED_MANAGER_VERSION" ||
      "$ACTUAL_MANAGER_BUILD" != "$EXPECTED_MANAGER_BUILD" ]]; then
  echo "Integrated manager version does not match project metadata." >&2
  exit 65
fi

"$PROJECT_DIR/scripts/verify-release.sh" "$APP_PATH"

if [[ ! -d "$RUNTIME_APP" ]]; then
  echo "Integrated app is missing NeAntik Browser.app." >&2
  exit 66
fi

RUNTIME_PLIST="$RUNTIME_APP/Contents/Info.plist"
for expectation in \
  "CFBundleDisplayName:NeAntik Browser" \
  "CFBundleIdentifier:app.neantik.runtime" \
  "NeAntikRuntimeFlavor:fingerprint-chromium"; do
  key="${expectation%%:*}"
  expected="${expectation#*:}"
  actual="$(plutil -extract "$key" raw -o - "$RUNTIME_PLIST")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Unexpected runtime $key: $actual" >&2
    exit 65
  fi
done

RUNTIME_BUILD_MODE="$(
  plutil -extract NeAntikRuntimeBuildMode raw -o - "$RUNTIME_PLIST"
)"
case "$RUNTIME_BUILD_MODE" in
  no-metal-integration|source-build|metal-integration) ;;
  *)
    echo "Unexpected runtime build mode: $RUNTIME_BUILD_MODE" >&2
    exit 65
    ;;
esac

if ! cmp -s \
  "$PROJECT_DIR/runtime/fingerprint-chromium.lock.json" \
  "$EVIDENCE/fingerprint-chromium.lock.json"; then
  echo "Integrated source lock does not match the project lock." >&2
  exit 65
fi

if ! cmp -s \
  "$PROJECT_DIR/runtime/security-baseline.json" \
  "$EVIDENCE/security-baseline.json"; then
  echo "Integrated runtime security baseline does not match the project baseline." >&2
  exit 65
fi

if ! cmp -s \
  "$PROJECT_DIR/Resources/NeAntik.icns" \
  "$RUNTIME_APP/Contents/Resources/app.icns"; then
  echo "Integrated runtime does not contain the NeAntik icon." >&2
  exit 65
fi

for required in \
  "$EVIDENCE/args.gn" \
  "$EVIDENCE/runtime-verification.json" \
  "$APP_PATH/Contents/Resources/NeAntikRuntimeNotices.md" \
  "$LICENSES/Chromium-LICENSE" \
  "$LICENSES/fingerprint-chromium-LICENSE" \
  "$LICENSES/ungoogled-chromium-macos-LICENSE"; do
  if [[ ! -f "$required" ]]; then
    echo "Integrated release is missing: $required" >&2
    exit 66
  fi
done

for discovery_string in \
  "NeAntik Browser.app" \
  "app.neantik.runtime" \
  "fingerprint-chromium"; do
  if ! grep -aFq "$discovery_string" "$MANAGER_EXECUTABLE"; then
    echo "Manager is missing integrated-runtime contract: $discovery_string" >&2
    exit 65
  fi
done

license_hashes=(
  "368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b:$LICENSES/Chromium-LICENSE"
  "78bc4abfc3e5606b5b88c3cb9409a3250a7f64cffe704bef0563e11910a29189:$LICENSES/fingerprint-chromium-LICENSE"
  "2fdd1ed451121c07df0726a8ac8b86b49315d89a22c683edaf98b579e710504b:$LICENSES/ungoogled-chromium-macos-LICENSE"
)
for expectation in "${license_hashes[@]}"; do
  expected="${expectation%%:*}"
  license_path="${expectation#*:}"
  actual="$(shasum -a 256 "$license_path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Integrated license hash mismatch: $license_path" >&2
    exit 65
  fi
done

"$PROJECT_DIR/scripts/verify-built-runtime.sh" \
  "$RUNTIME_APP" \
  "$REPORT" \
  "$EVIDENCE/args.gn"
"$PROJECT_DIR/scripts/verify-runtime-report-consistency.py" \
  "$EVIDENCE/runtime-verification.json" \
  "$REPORT"
"$PROJECT_DIR/scripts/verify-runtime-compliance.sh" "$COMPLIANCE"

if ! CODESIGN_VERIFY_OUTPUT="$(
  codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1
)"; then
  printf '%s\n' "$CODESIGN_VERIFY_OUTPUT" >&2
  exit 65
fi

METAL_TRUE_COUNT="$(
  grep -Ec \
    '^[[:space:]]*angle_enable_metal[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
    "$EVIDENCE/args.gn" || true
)"
METAL_FALSE_COUNT="$(
  grep -Ec \
    '^[[:space:]]*angle_enable_metal[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
    "$EVIDENCE/args.gn" || true
)"
if (( METAL_TRUE_COUNT == 1 && METAL_FALSE_COUNT == 0 )); then
  GPU_MODE="metal"
elif (( METAL_FALSE_COUNT == 1 && METAL_TRUE_COUNT == 0 )); then
  GPU_MODE="no-metal"
else
  echo "Integrated args.gn must explicitly declare angle_enable_metal exactly once." >&2
  exit 65
fi

echo "Integrated NeAntik Direct release verified."
echo "Manager: NeAntik $ACTUAL_MANAGER_VERSION ($ACTUAL_MANAGER_BUILD), ARM64"
echo "Runtime: NeAntik Browser $EXPECTED_RUNTIME_VERSION, ARM64"
echo "Mode:    $RUNTIME_BUILD_MODE ($GPU_MODE verified by args.gn)"
echo "Notices: Chromium-generated, SPDX verified"
