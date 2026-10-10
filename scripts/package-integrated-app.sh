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

RUNTIME_VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - \
    "$CANDIDATE_LOCK" 2>/dev/null || true
)"
if [[ "$RUNTIME_VERSION" == 153.* ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-153-port-status.json"
  SOURCE_CONTRACT_NAME="chromium-153-port-status.json"
elif [[ "$RUNTIME_VERSION" == "154.0.8037.93" ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-154-source-contract.json"
  SOURCE_CONTRACT_NAME="chromium-154-source-contract.json"
elif [[ "$RUNTIME_VERSION" == "154.0.8037.98" ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-15498-source-contract.json"
  # The bundled evidence schema pins this public path for M154 contracts.
  SOURCE_CONTRACT_NAME="chromium-154-source-contract.json"
elif [[ "$RUNTIME_VERSION" == "155.0.8059.40" ]]; then
  M155_EVIDENCE_PREFIX="$(python3 "$PROJECT_DIR/scripts/chromium_15540_variant.py" "$CANDIDATE_LOCK")"
  SOURCE_CONTRACT_NAME="${M155_EVIDENCE_PREFIX}-source-contract.json"
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/$SOURCE_CONTRACT_NAME"
elif [[ "$RUNTIME_VERSION" == "156.0.8078.12" ]]; then
  SOURCE_CONTRACT_NAME="chromium-15612-source-contract.json"
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/$SOURCE_CONTRACT_NAME"
elif [[ "$RUNTIME_VERSION" == "152.0.7977.64" ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-152-source-contract.json"
  SOURCE_CONTRACT_NAME="chromium-152-source-contract.json"
else
  echo "Unsupported Chromium runtime version for packaging: $RUNTIME_VERSION" >&2
  exit 65
fi

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
python3 "$PROJECT_DIR/scripts/runtime_build_path.py" \
  "$SOURCE_ROOT" "$BUILD_ARGS" "$CANDIDATE_LOCK" >/dev/null
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
if [[ "$RUNTIME_VERSION" != "154.0.8037.93" &&
      "$RUNTIME_VERSION" != "154.0.8037.98" &&
      "$RUNTIME_VERSION" != "155.0.8059.40" &&
      "$RUNTIME_VERSION" != "156.0.8078.12" ]]; then
  python3 "$PROJECT_DIR/scripts/generate-runtime-integration-notices.py" --check
fi
if [[ "$RUNTIME_VERSION" == "154.0.8037.93" ||
      "$RUNTIME_VERSION" == "154.0.8037.98" ||
      "$RUNTIME_VERSION" == "155.0.8059.40" ||
      "$RUNTIME_VERSION" == "156.0.8078.12" ]]; then
  # Generated below in temporary compliance storage from this exact candidate.
  RUNTIME_NOTICES_FILE=""
elif [[ "$RUNTIME_VERSION" == 153.* ]]; then
  RUNTIME_NOTICES_FILE="$PROJECT_DIR/docs/RUNTIME_INTEGRATION_NOTICES_153.md"
else
  RUNTIME_NOTICES_FILE="$PROJECT_DIR/docs/RUNTIME_INTEGRATION_NOTICES.md"
fi

VERIFY_REPORT="$(mktemp -t nevision-integrated-runtime)"
COMPLIANCE_DIR="$(mktemp -d -t nevision-runtime-compliance)"
SNAPSHOT_ROOT="$(mktemp -d -t nevision-integrated-input)"
SNAPSHOT_RUNTIME="$SNAPSHOT_ROOT/NeAntik Browser.app"
SNAPSHOT_ARGS="$SNAPSHOT_ROOT/args.gn"
cleanup() {
  rm -f "$VERIFY_REPORT"
  rm -rf "$COMPLIANCE_DIR" "$SNAPSHOT_ROOT"
}
trap cleanup EXIT
if [[ "$RUNTIME_VERSION" == "154.0.8037.93" ||
      "$RUNTIME_VERSION" == "154.0.8037.98" ||
      "$RUNTIME_VERSION" == "155.0.8059.40" ||
      "$RUNTIME_VERSION" == "156.0.8078.12" ]]; then
  RUNTIME_NOTICES_FILE="$COMPLIANCE_DIR/RUNTIME_INTEGRATION_NOTICES_${RUNTIME_VERSION%%.*}.md"
  python3 "$PROJECT_DIR/scripts/generate-runtime-integration-notices.py" \
    --runtime-lock "$CANDIDATE_LOCK" --output "$RUNTIME_NOTICES_FILE"
fi
"$PROJECT_DIR/scripts/verify-built-runtime.sh" \
  "$RUNTIME_APP" \
  "$VERIFY_REPORT" \
  "$BUILD_ARGS" \
  "$SOURCE_PROVENANCE" \
  "$CANDIDATE_LOCK"
"$PROJECT_DIR/scripts/generate-runtime-compliance.sh" \
  "$SOURCE_ROOT" \
  "$COMPLIANCE_DIR" \
  "$CANDIDATE_LOCK" \
  "$BUILD_ARGS"
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
cp "$SOURCE_CONTRACT_FILE" \
  "$EVIDENCE/$SOURCE_CONTRACT_NAME"
cp "$SOURCE_PROVENANCE" \
  "$EVIDENCE/source-provenance.json"
if [[ "$RUNTIME_VERSION" == "154.0.8037.93" ]]; then
  cp "$PROJECT_DIR/runtime/chromium-154-device-memory-hotfix.json" \
    "$EVIDENCE/chromium-154-device-memory-hotfix.json"
  cp "$PROJECT_DIR/runtime/chromium-154-posthotfix-source-snapshot.json" \
    "$EVIDENCE/chromium-154-posthotfix-source-snapshot.json"
elif [[ "$RUNTIME_VERSION" == "154.0.8037.98" ]]; then
  cp "$PROJECT_DIR/runtime/chromium-15498-source-input-manifest.json" \
    "$EVIDENCE/chromium-15498-source-input-manifest.json"
  cp "$PROJECT_DIR/runtime/chromium-15498-source-snapshot.json" \
    "$EVIDENCE/chromium-15498-source-snapshot.json"
  cp "$PROJECT_DIR/runtime/chromium-15498-rebase-plan.json" \
    "$EVIDENCE/chromium-15498-rebase-plan.json"
  mkdir -p "$EVIDENCE/chromium-15498-source-evidence"
  ditto "$PROJECT_DIR/runtime/chromium-15498-source-evidence" \
    "$EVIDENCE/chromium-15498-source-evidence"
elif [[ "$RUNTIME_VERSION" == "155.0.8059.40" ]]; then
  python3 "$PROJECT_DIR/scripts/chromium_15540_packaged_evidence.py" "$CANDIDATE_LOCK" "$EVIDENCE" --copy
elif [[ "$RUNTIME_VERSION" == "156.0.8078.12" ]]; then
  python3 "$PROJECT_DIR/scripts/chromium_15612_packaged_evidence.py" "$CANDIDATE_LOCK" "$EVIDENCE" --copy
fi
cp "$SNAPSHOT_ARGS" "$EVIDENCE/args.gn"
cp "$VERIFY_REPORT" "$EVIDENCE/runtime-verification.json"
cp "$RUNTIME_NOTICES_FILE" \
  "$RESOURCES/NeAntikRuntimeNotices.md"
ditto "$COMPLIANCE_DIR" "$COMPLIANCE"

cp "$PROJECT_DIR/runtime/licenses/Chromium-LICENSE" \
  "$LICENSES/Chromium-LICENSE"
cp "$PROJECT_DIR/runtime/licenses/fingerprint-chromium-LICENSE" \
  "$LICENSES/fingerprint-chromium-LICENSE"
cp "$PROJECT_DIR/runtime/licenses/ungoogled-chromium-macos-LICENSE" \
  "$LICENSES/ungoogled-chromium-macos-LICENSE"

codesign --force --sign - \
  --entitlements "$PROJECT_DIR/runtime/neantik-direct-entitlements.plist" \
  "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

# The full Direct verifier intentionally accepts only the public bundle name
# NeAntik.app. Move the exact engineering bundle into a private public-name
# verification path, verify it without weakening that gate, then restore the
# engineering artifact for prepare-direct-runtime-candidate.sh.
python3 "$PROJECT_DIR/scripts/verify-public-named-bundle.py" \
  --engineering-app "$OUTPUT_APP" \
  --verifier "$PROJECT_DIR/scripts/verify-integrated-release.sh"

echo "$OUTPUT_APP"
