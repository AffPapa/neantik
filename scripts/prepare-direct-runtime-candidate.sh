#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINEERING_APP="$PROJECT_DIR/dist/NeAntik-Integrated.app"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
SECURITY_BASELINE_ARGS=()

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 /absolute/path/to/NeAntik\\ Browser.app /absolute/path/to/args.gn /absolute/path/to/chromium/src /absolute/path/to/runtime-candidate-lock.json" >&2
  exit 64
fi

RUNTIME_APP="$1"
BUILD_ARGS="$2"
SOURCE_ROOT="$3"
CANDIDATE_LOCK="$4"
SOURCE_PROVENANCE="$(dirname "$SOURCE_ROOT")/source-provenance.json"
PACKAGING_DIR="$(dirname "$RUNTIME_APP")/NeAntik Browser Packaging"

for input in "$RUNTIME_APP" "$BUILD_ARGS" "$SOURCE_ROOT" "$CANDIDATE_LOCK"; do
  if [[ "$input" != /* || ! -e "$input" ]]; then
    echo "Direct candidate inputs must be existing absolute paths: $input" >&2
    exit 66
  fi
done
if [[ -e "$CANDIDATE_MANIFEST" || -L "$CANDIDATE_MANIFEST" ]]; then
  echo "Prepared candidate manifest already exists; refusing to replace it." >&2
  exit 65
fi

EXPECTED_BUILD_ARGS="$SOURCE_ROOT/out/Default/args.gn"
if [[ "$(cd "$(dirname "$BUILD_ARGS")" && pwd -P)/$(basename "$BUILD_ARGS")" !=
      "$(cd "$(dirname "$EXPECTED_BUILD_ARGS")" && pwd -P)/$(basename "$EXPECTED_BUILD_ARGS")" ]]; then
  echo "Direct candidate requires canonical source-root out/Default/args.gn." >&2
  exit 65
fi
EXPECTED_CANDIDATE_LOCK="$(dirname "$SOURCE_ROOT")/runtime-candidate-lock.json"
if [[ "$(cd "$(dirname "$CANDIDATE_LOCK")" && pwd -P)/$(basename "$CANDIDATE_LOCK")" !=
      "$(cd "$(dirname "$EXPECTED_CANDIDATE_LOCK")" && pwd -P)/$(basename "$EXPECTED_CANDIDATE_LOCK")" ]]; then
  echo "Direct candidate requires the lock emitted for this build root." >&2
  exit 65
fi
if [[ ! -f "$SOURCE_PROVENANCE" || -L "$SOURCE_PROVENANCE" ]]; then
  echo "Direct candidate requires generated Chromium source provenance." >&2
  exit 66
fi

case "${NEANTIK_RELEASE_CHANNEL:-}" in
  public-alpha)
    SECURITY_BASELINE_ARGS+=(--allow-public-alpha-tuples)
    ;;
  production)
    ;;
  *)
    echo "Set NEANTIK_RELEASE_CHANNEL to public-alpha or production." >&2
    exit 64
    ;;
esac
: "${NEANTIK_SIGNING_IDENTITY:?Set NEANTIK_SIGNING_IDENTITY to a Developer ID Application identity}"

METAL_TRUE_COUNT="$(
  grep -Ec \
    '^[[:space:]]*angle_enable_metal[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
    "$BUILD_ARGS" || true
)"
METAL_FALSE_COUNT="$(
  grep -Ec \
    '^[[:space:]]*angle_enable_metal[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
    "$BUILD_ARGS" || true
)"
if (( METAL_TRUE_COUNT != 1 || METAL_FALSE_COUNT != 0 )); then
  echo "Public Direct candidate requires one explicit angle_enable_metal=true declaration." >&2
  exit 65
fi

"$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" \
  "$SOURCE_PROVENANCE" \
  --source-root "$SOURCE_ROOT"
"$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
  "$CANDIDATE_LOCK" \
  "$SOURCE_PROVENANCE"
"$PROJECT_DIR/scripts/verify-runtime-security-baseline.py" \
  --lock "$CANDIDATE_LOCK" \
  "${SECURITY_BASELINE_ARGS[@]}"
"$PROJECT_DIR/scripts/verify-direct-version-bump.py"
"$PROJECT_DIR/scripts/verify-direct-telemetry-disabled.py"
"$PROJECT_DIR/scripts/verify-direct-update-policy.py"
"$PROJECT_DIR/scripts/verify-public-fingerprint-corpus.py"
"$PROJECT_DIR/scripts/preflight-distribution.sh" direct

SIGNED_RUNTIME_ROOT="$(mktemp -d -t neantik-developer-id-runtime)"
SIGNED_RUNTIME="$SIGNED_RUNTIME_ROOT/NeAntik Browser.app"
cleanup() {
  rm -rf "$SIGNED_RUNTIME_ROOT"
}
trap cleanup EXIT

export NEANTIK_CHROMIUM_SOURCE_ROOT="$SOURCE_ROOT"
"$PROJECT_DIR/scripts/sign-runtime.sh" \
  "$RUNTIME_APP" \
  "$PACKAGING_DIR" \
  "$SIGNED_RUNTIME"
"$PROJECT_DIR/scripts/package-integrated-app.sh" \
  "$SIGNED_RUNTIME" \
  "$BUILD_ARGS" \
  "$SOURCE_ROOT" \
  "$CANDIDATE_LOCK"

rm -rf "$APP_PATH"
ditto "$ENGINEERING_APP" "$APP_PATH"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$NEANTIK_SIGNING_IDENTITY" \
  "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$APP_PATH"

python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" create \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL"

echo "$APP_PATH"
echo "$CANDIDATE_MANIFEST"
echo "Next: collect a fresh GUI A → B → A report from this exact app, then run scripts/release-direct.sh."
