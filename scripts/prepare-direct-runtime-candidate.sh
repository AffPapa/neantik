#!/bin/zsh

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

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
CHROMIUM_OUT_DIR="$(dirname "$BUILD_ARGS")"
SOURCE_ROOT="$3"
CANDIDATE_LOCK="$4"
SOURCE_PROVENANCE="$(dirname "$SOURCE_ROOT")/source-provenance.json"
PRIVACY_DERIVATION=0
if [[ "$(plutil -extract variant raw -o - "$CANDIDATE_LOCK" 2>/dev/null || true)" == "recipient-privacy-policy-v1" ]]; then
  PRIVACY_DERIVATION=1
  SOURCE_PROVENANCE="$(dirname "$CANDIDATE_LOCK")/source-provenance.json"
fi
PACKAGING_DIR="$(dirname "$RUNTIME_APP")/NeAntik Browser Packaging"

for input in "$RUNTIME_APP" "$BUILD_ARGS" "$SOURCE_ROOT" "$CANDIDATE_LOCK"; do
  if [[ "$input" != /* || ! -e "$input" ]]; then
    echo "Direct candidate inputs must be existing absolute paths: $input" >&2
    exit 66
  fi
done
if [[ -n "${NEANTIK_OWNED_WEBKIT_HOST_BINARY:-}" ||
      -n "${NEANTIK_OWNED_WEBKIT_FRAMEWORKS:-}" ]]; then
  echo "Owned WebKit is not release-enabled; direct candidate preparation refuses runtime injection." >&2
  exit 78
fi
if [[ -e "$CANDIDATE_MANIFEST" || -L "$CANDIDATE_MANIFEST" ]]; then
  echo "Prepared candidate manifest already exists; refusing to replace it." >&2
  exit 65
fi
for existing_output in "$APP_PATH" "$ENGINEERING_APP"; do
  if [[ -e "$existing_output" || -L "$existing_output" ]]; then
    echo "A previous prepared or partial app exists; preserve it and resume or diagnose before retrying: $existing_output" >&2
    exit 65
  fi
done

python3 "$PROJECT_DIR/scripts/runtime_build_path.py" \
  "$SOURCE_ROOT" "$BUILD_ARGS" "$CANDIDATE_LOCK" >/dev/null
for compliance_input in \
  "$SOURCE_ROOT/tools/licenses/licenses.py" \
  "$CHROMIUM_OUT_DIR/gen/components/resources/about_credits.html"; do
  if [[ ! -f "$compliance_input" || -L "$compliance_input" ]]; then
    echo "Required compliance input is unavailable before signing: $compliance_input" >&2
    exit 66
  fi
done
EXPECTED_CANDIDATE_LOCK="$(dirname "$SOURCE_ROOT")/runtime-candidate-lock.json"
if (( PRIVACY_DERIVATION == 1 )); then
  EXPECTED_CANDIDATE_LOCK="$(dirname "$SOURCE_PROVENANCE")/runtime-candidate-lock.json"
fi
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

if [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "156.0.8078.12" ]]; then
  : "${NEANTIK_M156_BUILD_EVIDENCE:?Set the private final9 executed build evidence directory}"
  "$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" "$SOURCE_PROVENANCE" \
    --built-source-root "$SOURCE_ROOT" --build-evidence "$NEANTIK_M156_BUILD_EVIDENCE"
else
  "$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" \
  "$SOURCE_PROVENANCE" \
  --source-root "$SOURCE_ROOT"
fi
"$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
  "$CANDIDATE_LOCK" \
  "$SOURCE_PROVENANCE"
"$PROJECT_DIR/scripts/verify-runtime-security-baseline.py" \
  --lock "$CANDIDATE_LOCK" \
  "${SECURITY_BASELINE_ARGS[@]}"
"$PROJECT_DIR/scripts/verify-direct-version-bump.py"
"$PROJECT_DIR/scripts/verify-direct-telemetry-disabled.py"
"$PROJECT_DIR/scripts/verify-direct-update-policy.py"
"$PROJECT_DIR/scripts/verify-browser-identity-issuance.py"
"$PROJECT_DIR/scripts/verify-public-fingerprint-corpus.py"
"$PROJECT_DIR/scripts/preflight-distribution.sh" direct
python3 -B "$PROJECT_DIR/scripts/native-qa-readiness.py" --check

SIGNED_RUNTIME_ROOT="$(mktemp -d -t neantik-developer-id-runtime)"
SIGNED_RUNTIME="$SIGNED_RUNTIME_ROOT/NeAntik Browser.app"
RUNTIME_REPORT="$SIGNED_RUNTIME_ROOT/runtime-verification.json"
cleanup() {
  local cleanup_status="$1"
  if (( cleanup_status == 0 )); then
    rm -rf "$SIGNED_RUNTIME_ROOT"
  else
    echo "Failed preparation inputs preserved: $SIGNED_RUNTIME_ROOT" >&2
  fi
}
trap 'cleanup $?' EXIT

export NEANTIK_CHROMIUM_SOURCE_ROOT="$SOURCE_ROOT"
CHROMIUM_SIGNING_CONFIG="$CHROMIUM_OUT_DIR/NeAntik Browser Packaging/signing/build_props_config.py"
if [[ -f "$CHROMIUM_OUT_DIR/build.ninja" && -d "$(dirname "$RUNTIME_APP")/NeAntik Browser Packaging" ]]; then
  if [[ "$(cd "$(dirname "$RUNTIME_APP")" && pwd -P)" != "$(cd "$CHROMIUM_OUT_DIR" && pwd -P)" ]]; then
    echo "Chromium runtime app and args.gn must share the selected GN output directory." >&2
    exit 65
  fi
  NINJA_BIN="$SOURCE_ROOT/third_party/ninja/ninja"
  if [[ ! -f "$CHROMIUM_OUT_DIR/.ninja_log" || -L "$CHROMIUM_OUT_DIR/.ninja_log" ]]; then
    if [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" != "156.0.8078.80" ]]; then
      echo "Pinned Chromium Ninja or build log is unavailable; preserve the output and diagnose before retrying." >&2
      exit 65
    fi
    # Reproduce only the pinned sign_config Python action in an isolated copy.
    # This does not recreate a build log or validate the existing runtime.
    PACKAGING_DIR="$SIGNED_RUNTIME_ROOT/NeAntik Browser Packaging"
    python3 -B "$PROJECT_DIR/scripts/prepare-chromium-15680-signing-package.py" \
      "$SOURCE_ROOT" "$CHROMIUM_OUT_DIR" "$PACKAGING_DIR"
  else
    if [[ ! -x "$NINJA_BIN" || -L "$NINJA_BIN" ]]; then
      echo "Pinned Chromium Ninja or build log is unavailable; preserve the output and diagnose before retrying." >&2
      exit 65
    fi
    "$NINJA_BIN" -C "$CHROMIUM_OUT_DIR" 'NeAntik Browser Packaging/signing/build_props_config.py'
    if [[ ! -f "$CHROMIUM_SIGNING_CONFIG" || -L "$CHROMIUM_SIGNING_CONFIG" ]]; then
      echo "Chromium GN signing configuration was not regenerated safely." >&2
      exit 65
    fi
  fi
fi
if [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "154.0.8037.93" ]]; then
  python3 "$PROJECT_DIR/scripts/verify-chromium-154-unsigned-candidate.py" \
    "$RUNTIME_APP" "$BUILD_ARGS" "$SOURCE_PROVENANCE"
elif [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "154.0.8037.98" ]]; then
  python3 "$PROJECT_DIR/scripts/verify-chromium-15498-unsigned-candidate.py" \
    "$RUNTIME_APP" "$BUILD_ARGS" "$SOURCE_PROVENANCE"
elif [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "155.0.8059.40" ]]; then
  python3 "$PROJECT_DIR/scripts/verify-chromium-15540-unsigned-candidate.py" \
    "$RUNTIME_APP" "$BUILD_ARGS" "$SOURCE_PROVENANCE"
elif [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "156.0.8078.12" ]]; then
  python3 "$PROJECT_DIR/scripts/verify-chromium-15612-unsigned-candidate.py" \
    "$RUNTIME_APP" "$BUILD_ARGS" "$SOURCE_PROVENANCE"
elif [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "156.0.8078.74" ]]; then
  python3 "$PROJECT_DIR/scripts/verify-chromium-15674-unsigned-candidate.py" \
    "$RUNTIME_APP" "$BUILD_ARGS" "$PROJECT_DIR/runtime/chromium-15674-source-adoption-v1.json"
elif [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "156.0.8078.80" ]]; then
  PRIVACY_VERIFY_ARGS=()
  if (( PRIVACY_DERIVATION == 1 )); then PRIVACY_VERIFY_ARGS+=(--runtime-lock "$CANDIDATE_LOCK"); fi
  python3 "$PROJECT_DIR/scripts/verify-chromium-15680-unsigned-candidate.py" \
    "$RUNTIME_APP" "$BUILD_ARGS" "$PROJECT_DIR/runtime/chromium-15680-source-adoption-v1.json" "${PRIVACY_VERIFY_ARGS[@]}"
fi
if (( PRIVACY_DERIVATION == 1 )); then
  export NEANTIK_RUNTIME_SIGNING_FRAMEWORK_SHA256="$(plutil -extract binaryBinding.unsignedFrameworkSHA256 raw -o - "$CANDIDATE_LOCK")"
fi
if [[ -n "${NEANTIK_REUSE_SIGNED_RUNTIME:-}" ]]; then
  if (( PRIVACY_DERIVATION != 1 )) || [[ "$NEANTIK_REUSE_SIGNED_RUNTIME" != /* ||
      -L "$NEANTIK_REUSE_SIGNED_RUNTIME" || ! -d "$NEANTIK_REUSE_SIGNED_RUNTIME" ]]; then
    echo "Preserved signing input is available only for the selected privacy derivation." >&2
    exit 65
  fi
  # Reuse exact qualified runtime bytes. The verifier below must reproduce the
  # compiled frozen report; a fresh signature would invalidate capability pins.
  ditto "$NEANTIK_REUSE_SIGNED_RUNTIME" "$SIGNED_RUNTIME"
else
"$PROJECT_DIR/scripts/sign-runtime.sh" \
  "$RUNTIME_APP" \
  "$PACKAGING_DIR" \
  "$SIGNED_RUNTIME"
fi
"$PROJECT_DIR/scripts/verify-built-runtime.sh" \
  "$SIGNED_RUNTIME" \
  "$RUNTIME_REPORT" \
  "$BUILD_ARGS" \
  "$SOURCE_PROVENANCE" \
  "$CANDIDATE_LOCK"
python3 "$PROJECT_DIR/scripts/promote-runtime-candidate-lock.py" \
  "$CANDIDATE_LOCK" \
  "$SOURCE_PROVENANCE" \
  "$SIGNED_RUNTIME" \
  "$BUILD_ARGS" \
  "$RUNTIME_REPORT" \
  --source-root "$SOURCE_ROOT" \
  --confirm-promote-source-lock
RUNTIME_NOTICES_MAJOR="$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")"
RUNTIME_NOTICES_MAJOR="${RUNTIME_NOTICES_MAJOR%%.*}"
if [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "154.0.8037.93" ||
      "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "154.0.8037.98" ||
      "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "155.0.8059.40" ||
      "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "156.0.8078.12" ]]; then
  python3 "$PROJECT_DIR/scripts/generate-runtime-integration-notices.py" \
    --runtime-lock "$CANDIDATE_LOCK" \
    --output "$PROJECT_DIR/docs/RUNTIME_INTEGRATION_NOTICES_${RUNTIME_NOTICES_MAJOR}.md"
elif [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_LOCK")" == "156.0.8078.80" ]]; then
  # The integrated packager writes notices from this exact .80 lock. Do not
  # render the default notice file from the unrelated published runtime lock.
  :
else
  python3 "$PROJECT_DIR/scripts/generate-runtime-integration-notices.py"
fi
# Preserve the caller's explicit backup opt-in and authenticated provisioning.
# Forcing a legacy capability here conflicts with approved release metadata.
"$PROJECT_DIR/scripts/package-integrated-app.sh" \
  "$SIGNED_RUNTIME" \
  "$BUILD_ARGS" \
  "$SOURCE_ROOT" \
  "$CANDIDATE_LOCK"

rm -rf "$APP_PATH"
ditto "$ENGINEERING_APP" "$APP_PATH"
python3 "$PROJECT_DIR/scripts/direct_backup_signing.py" sign "$APP_PATH" "$NEANTIK_SIGNING_IDENTITY"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$APP_PATH"

PRIVATE_RELEASE_BASE="$PROJECT_DIR/dist/private"
python3 -B "$PROJECT_DIR/scripts/native-qa-readiness.py" --check
if [[ -L "$PRIVATE_RELEASE_BASE" ||
      (-e "$PRIVATE_RELEASE_BASE" && ! -d "$PRIVATE_RELEASE_BASE") ]]; then
  echo "Private release state path is unsafe." >&2
  exit 65
fi
/bin/mkdir -p "$PRIVATE_RELEASE_BASE"
if [[ -L "$PRIVATE_RELEASE_BASE" ||
      "$(/usr/bin/stat -f '%u' "$PRIVATE_RELEASE_BASE")" != "$EUID" ]]; then
  echo "Private release state directory is unsafe." >&2
  exit 65
fi
/bin/chmod 0700 "$PRIVATE_RELEASE_BASE"
PRIVATE_RELEASE_DIR="$(
  /usr/bin/mktemp -d \
    "$PRIVATE_RELEASE_BASE/fingerprint-enrollment.XXXXXX"
)"
/bin/chmod 0700 "$PRIVATE_RELEASE_DIR"
FINGERPRINT_ENROLLMENT="$PRIVATE_RELEASE_DIR/fingerprint-enrollment.json"
"$PROJECT_DIR/scripts/enroll-direct-fingerprint-authority.sh" \
  "$APP_PATH" \
  "$FINGERPRINT_ENROLLMENT"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$APP_PATH"

python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" create \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL" \
  --fingerprint-enrollment "$FINGERPRINT_ENROLLMENT"

echo "$APP_PATH"
echo "$CANDIDATE_MANIFEST"
echo "Next: collect a fresh GUI A → B → A report from this exact app, then run scripts/release-direct.sh."
