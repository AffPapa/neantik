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
ACTUAL_MANAGER_DEVELOPMENT_REGION="$(
  plutil -extract CFBundleDevelopmentRegion raw -o - \
    "$APP_PATH/Contents/Info.plist"
)"
if [[ "$ACTUAL_MANAGER_VERSION" != "$EXPECTED_MANAGER_VERSION" ||
      "$ACTUAL_MANAGER_BUILD" != "$EXPECTED_MANAGER_BUILD" ]]; then
  echo "Integrated manager version does not match project metadata." >&2
  exit 65
fi
if [[ "$ACTUAL_MANAGER_DEVELOPMENT_REGION" != "ru" ]]; then
  echo "Integrated manager development region must be ru." >&2
  exit 65
fi

for localized_resource in InfoPlist.strings Localizable.strings; do
  expected="$PROJECT_DIR/Resources/ru.lproj/$localized_resource"
  packaged="$APP_PATH/Contents/Resources/ru.lproj/$localized_resource"
  if [[ ! -f "$packaged" || -L "$packaged" ]] ||
     ! cmp -s "$expected" "$packaged"; then
    echo "Integrated manager localization does not match project resource: $localized_resource" >&2
    exit 65
  fi
done

RELEASE_CHROMIUM_VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - \
    "$EVIDENCE/fingerprint-chromium.lock.json"
)"
if [[ "$RELEASE_CHROMIUM_VERSION" == "156.0.8078.80" ]]; then
  ENGINE_SCOPE="$(plutil -extract NeAntikEngineScope raw -o - "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$ENGINE_SCOPE" != "chromium-only" ]]; then
    echo "Chromium 156.80 candidate is missing the Chromium-only manager build marker." >&2
    exit 65
  fi
  for forbidden_path in \
    "$APP_PATH/Contents/Helpers/webkit-v1" \
    "$APP_PATH/Contents/Helpers/NeAntikWebKitHost.app"; do
    if [[ -e "$forbidden_path" || -L "$forbidden_path" ]]; then
      echo "Chromium-only candidate contains an owned WebKit host path: $forbidden_path" >&2
      exit 65
    fi
  done
  WEBKIT_FRAMEWORK="$(/usr/bin/find "$APP_PATH/Contents" \
    \( -name 'NeAntikWebKitHost.app' -o -name 'WebKit.framework' \
       -o -name 'WebCore.framework' -o -name 'JavaScriptCore.framework' \) \
    -print -quit 2>/dev/null || true)"
  if [[ -n "$WEBKIT_FRAMEWORK" ]]; then
    echo "Chromium-only candidate contains a WebKit host or framework: $WEBKIT_FRAMEWORK" >&2
    exit 65
  fi
fi

OWNED_WEBKIT_HOST="$APP_PATH/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app"
if [[ -e "$OWNED_WEBKIT_HOST" || -L "$OWNED_WEBKIT_HOST" ]]; then
  WEBKIT_SOURCE_OFFER="${NEANTIK_WEBKIT_SOURCE_OFFER_ROOT:-}"
  if [[ "$WEBKIT_SOURCE_OFFER" != /* || -L "$WEBKIT_SOURCE_OFFER" ||
        ! -d "$WEBKIT_SOURCE_OFFER" ]]; then
    echo "Owned WebKit verification requires the exact physical source-offer directory." >&2
    exit 65
  fi
  WEBKIT_OFFER_DIGEST_ARGS=()
  if [[ -n "${NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256:-}" ]]; then
    if [[ ! "$NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256" =~ '^[0-9a-f]{64}$' ]]; then
      echo "Owned WebKit source-offer manifest SHA-256 is invalid." >&2
      exit 65
    fi
    WEBKIT_OFFER_DIGEST_ARGS=(--source-offer-manifest-sha256 "$NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256")
  fi
  python3 -B "$PROJECT_DIR/scripts/verify-webkit-host-pin.py" "$APP_PATH"
  python3 -B "$PROJECT_DIR/scripts/webkit_runtime_notices.py" \
    --verify --app "$APP_PATH" \
    --runtime-frameworks "$OWNED_WEBKIT_HOST/Contents/Frameworks" \
    --source-offer-root "$WEBKIT_SOURCE_OFFER" \
    "${WEBKIT_OFFER_DIGEST_ARGS[@]}" \
    --project-root "$PROJECT_DIR"
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

EXPECTED_RUNTIME_VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - \
    "$EVIDENCE/fingerprint-chromium.lock.json"
)"
if [[ "$EXPECTED_RUNTIME_VERSION" == 153.* ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-153-port-status.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/chromium-153-port-status.json"
  SOURCE_PROVENANCE_FILE="$PROJECT_DIR/runtime/chromium-153-port-candidate.json"
  CANDIDATE_LOCK_FILE="$PROJECT_DIR/runtime/fingerprint-chromium-153.lock.json"
elif [[ "$EXPECTED_RUNTIME_VERSION" == 152.* ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-152-source-contract.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/chromium-152-source-contract.json"
  SOURCE_PROVENANCE_FILE="$EVIDENCE/source-provenance.json"
  CANDIDATE_LOCK_FILE="$EVIDENCE/fingerprint-chromium.lock.json"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.93" ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-154-source-contract.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/chromium-154-source-contract.json"
  SOURCE_PROVENANCE_FILE="$PROJECT_DIR/runtime/chromium-154-port-candidate.json"
  CANDIDATE_LOCK_FILE="$PROJECT_DIR/runtime/fingerprint-chromium-154.lock.json"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.98" ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-15498-source-contract.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/chromium-154-source-contract.json"
  SOURCE_PROVENANCE_FILE="$PROJECT_DIR/runtime/chromium-15498-port-candidate.json"
  CANDIDATE_LOCK_FILE="$PROJECT_DIR/runtime/fingerprint-chromium-15498.lock.json"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "155.0.8059.40" ]]; then
  M155_EVIDENCE_PREFIX="$(python3 "$PROJECT_DIR/scripts/chromium_15540_variant.py" "$EVIDENCE/fingerprint-chromium.lock.json")"
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/${M155_EVIDENCE_PREFIX}-source-contract.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/${M155_EVIDENCE_PREFIX}-source-contract.json"
  SOURCE_PROVENANCE_FILE="$PROJECT_DIR/runtime/${M155_EVIDENCE_PREFIX}-port-candidate.json"
  CANDIDATE_LOCK_FILE="$PROJECT_DIR/runtime/fingerprint-${M155_EVIDENCE_PREFIX}.lock.json"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.12" ]]; then
  M156_EVIDENCE_PREFIX="$(python3 "$PROJECT_DIR/scripts/chromium_15612_variant.py" "$EVIDENCE/fingerprint-chromium.lock.json")"
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/${M156_EVIDENCE_PREFIX}-source-contract.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/${M156_EVIDENCE_PREFIX}-source-contract.json"
  SOURCE_PROVENANCE_FILE="$PROJECT_DIR/runtime/${M156_EVIDENCE_PREFIX}-port-candidate.json"
  CANDIDATE_LOCK_FILE="$PROJECT_DIR/runtime/fingerprint-${M156_EVIDENCE_PREFIX}.lock.json"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.48" ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-15648-source-contract.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/chromium-15648-source-contract.json"
  SOURCE_PROVENANCE_FILE="$EVIDENCE/source-provenance.json"
  CANDIDATE_LOCK_FILE="$EVIDENCE/fingerprint-chromium.lock.json"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.74" ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-15674-source-contract.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/chromium-15674-source-contract.json"
  SOURCE_PROVENANCE_FILE="$EVIDENCE/source-provenance.json"
  CANDIDATE_LOCK_FILE="$EVIDENCE/fingerprint-chromium.lock.json"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.80" ]]; then
  SOURCE_CONTRACT_FILE="$PROJECT_DIR/runtime/chromium-15680-source-contract.json"
  PACKAGED_SOURCE_CONTRACT="$EVIDENCE/chromium-15680-source-contract.json"
  SOURCE_PROVENANCE_FILE="$EVIDENCE/source-provenance.json"
  CANDIDATE_LOCK_FILE="$EVIDENCE/fingerprint-chromium.lock.json"
else
  echo "Unsupported Chromium runtime version for integrated release verification: $EXPECTED_RUNTIME_VERSION" >&2
  exit 65
fi

# The runtime report pins its immutable historical baseline. The separate
# publication observation must still exactly match today's reviewed gate.
python3 "$PROJECT_DIR/scripts/package-manager-release-baseline.py" \
  --project-root "$PROJECT_DIR" --evidence "$EVIDENCE" --verify-only

if ! cmp -s \
  "$PROJECT_DIR/runtime/nevision-patches/series.json" \
  "$EVIDENCE/neantik-patch-series.json"; then
  echo "Integrated NeAntik patch series does not match the project manifest." >&2
  exit 65
fi

if ! cmp -s \
  "$PROJECT_DIR/runtime/apple-device-tuples.json" \
  "$EVIDENCE/apple-device-tuples.json"; then
  echo "Integrated Apple device tuples do not match the reviewed catalog." >&2
  exit 65
fi

if ! cmp -s "$SOURCE_CONTRACT_FILE" "$PACKAGED_SOURCE_CONTRACT"; then
  echo "Integrated Chromium source contract does not match the project contract." >&2
  exit 65
fi
if [[ "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.93" ]]; then
  for evidence_name in chromium-154-device-memory-hotfix.json chromium-154-posthotfix-source-snapshot.json; do
    if [[ ! -f "$EVIDENCE/$evidence_name" || -L "$EVIDENCE/$evidence_name" ]] ||
       ! cmp -s "$PROJECT_DIR/runtime/$evidence_name" "$EVIDENCE/$evidence_name"; then
      echo "Integrated M154 hotfix evidence differs from the reviewed source: $evidence_name" >&2
      exit 65
    fi
  done
elif [[ "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.98" ]]; then
  for evidence_name in chromium-15498-source-input-manifest.json chromium-15498-source-snapshot.json chromium-15498-rebase-plan.json; do
    if [[ ! -f "$EVIDENCE/$evidence_name" || -L "$EVIDENCE/$evidence_name" ]] ||
       ! cmp -s "$PROJECT_DIR/runtime/$evidence_name" "$EVIDENCE/$evidence_name"; then
      echo "Integrated M154.98 evidence differs from reviewed source: $evidence_name" >&2
      exit 65
    fi
  done
  for evidence_name in device-memory-hotfix.json external-build-inputs.json ordered-patch-replay.json port-compatibility.json; do
    if [[ ! -f "$EVIDENCE/chromium-15498-source-evidence/$evidence_name" ||
          -L "$EVIDENCE/chromium-15498-source-evidence/$evidence_name" ]] ||
       ! cmp -s "$PROJECT_DIR/runtime/chromium-15498-source-evidence/$evidence_name" \
         "$EVIDENCE/chromium-15498-source-evidence/$evidence_name"; then
      echo "Integrated M154.98 source evidence differs: $evidence_name" >&2
      exit 65
    fi
  done
elif [[ "$EXPECTED_RUNTIME_VERSION" == "155.0.8059.40" ]]; then
  python3 "$PROJECT_DIR/scripts/chromium_15540_packaged_evidence.py" "$EVIDENCE/fingerprint-chromium.lock.json" "$EVIDENCE"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.12" ]]; then
  python3 "$PROJECT_DIR/scripts/chromium_15612_packaged_evidence.py" "$EVIDENCE/fingerprint-chromium.lock.json" "$EVIDENCE"
elif [[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.48" ]]; then
  for evidence_name in chromium-15648-source-adoption-v3.json chromium-15648-deps-lock.json chromium-15648-neantik-v3.patch chromium-15648-devtools-typescript6.patch chromium-15648-v8-scope-iterator-compat.patch chromium-15648-rebase-plan.json; do
    if [[ ! -f "$EVIDENCE/chromium-15648-source-evidence/$evidence_name" || -L "$EVIDENCE/chromium-15648-source-evidence/$evidence_name" ]] ||
       ! cmp -s "$PROJECT_DIR/runtime/$evidence_name" "$EVIDENCE/chromium-15648-source-evidence/$evidence_name"; then
      echo "Integrated Chromium 156.48 source evidence differs: $evidence_name" >&2
      exit 65
    fi
  done
elif [[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.74" ]]; then
  for evidence_name in chromium-15674-source-adoption-v1.json chromium-15674-deps-lock.json chromium-15674-neantik.patch chromium-15674-devtools-typescript6.patch chromium-15674-v8-scope-iterator-compat.patch chromium-15674-rebase-plan.json chromium-15674-build-evidence.json chromium-15674-args.gn; do
    if [[ ! -f "$EVIDENCE/chromium-15674-source-evidence/$evidence_name" || -L "$EVIDENCE/chromium-15674-source-evidence/$evidence_name" ]] ||
       ! cmp -s "$PROJECT_DIR/runtime/$evidence_name" "$EVIDENCE/chromium-15674-source-evidence/$evidence_name"; then
      echo "Integrated Chromium 156.74 source evidence differs: $evidence_name" >&2
      exit 65
    fi
  done
elif [[ "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.80" ]]; then
  for evidence_name in chromium-15680-source-adoption-v1.json chromium-15680-deps-lock.json chromium-15680-neantik.patch chromium-15680-devtools-typescript6.patch chromium-15680-v8-scope-iterator-compat.patch chromium-15680-rebase-plan.json chromium-15680-build-evidence.json chromium-15680-args.gn; do
    if [[ ! -f "$EVIDENCE/chromium-15680-source-evidence/$evidence_name" || -L "$EVIDENCE/chromium-15680-source-evidence/$evidence_name" ]] ||
       ! cmp -s "$PROJECT_DIR/runtime/$evidence_name" "$EVIDENCE/chromium-15680-source-evidence/$evidence_name"; then
      echo "Integrated Chromium 156.80 source evidence differs: $evidence_name" >&2
      exit 65
    fi
  done
fi

if [[ "$EXPECTED_RUNTIME_VERSION" == 153.* ]]; then
  if ! cmp -s "$EVIDENCE/source-provenance.json" "$SOURCE_PROVENANCE_FILE";
  then
    echo "Integrated Chromium 153 source candidate evidence does not match." >&2
    exit 65
  fi
  if ! cmp -s "$EVIDENCE/fingerprint-chromium.lock.json" "$CANDIDATE_LOCK_FILE";
  then
    echo "Integrated Chromium 153 candidate lock does not match." >&2
    exit 65
  fi
elif [[ "$EXPECTED_RUNTIME_VERSION" == 152.* ||
        "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.93" ||
        "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.98" ||
        "$EXPECTED_RUNTIME_VERSION" == "155.0.8059.40" ||
        "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.12" ||
        "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.48" ||
        "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.74" ||
        "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.80" ]]; then
  "$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" \
    "$EVIDENCE/source-provenance.json"
  "$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
    "$EVIDENCE/fingerprint-chromium.lock.json" \
    "$EVIDENCE/source-provenance.json"
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
  "$EVIDENCE/neantik-patch-series.json" \
  "$EVIDENCE/apple-device-tuples.json" \
  "$PACKAGED_SOURCE_CONTRACT" \
  "$EVIDENCE/source-provenance.json" \
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

VERIFY_BUILT_RUNTIME_ARGS=("$RUNTIME_APP")
if [[ "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.58" ]]; then
  echo "Chromium 154.0.8037.58 is diagnostic-only and cannot be released." >&2
  exit 65
fi
if [[ "$EXPECTED_RUNTIME_VERSION" == 153.* ||
      "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.93" ||
      "$EXPECTED_RUNTIME_VERSION" == "154.0.8037.98" ||
        "$EXPECTED_RUNTIME_VERSION" == "155.0.8059.40" ||
      "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.12" ||
      "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.48" ||
      "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.74" ||
      "$EXPECTED_RUNTIME_VERSION" == "156.0.8078.80" ]]; then
  VERIFY_BUILT_RUNTIME_ARGS+=(
    ""
    "$EVIDENCE/args.gn"
    "$EVIDENCE/source-provenance.json"
    "$EVIDENCE/fingerprint-chromium.lock.json"
  )
  "$PROJECT_DIR/scripts/verify-built-runtime.sh" \
    "${VERIFY_BUILT_RUNTIME_ARGS[@]}"
else
"$PROJECT_DIR/scripts/verify-built-runtime.sh" \
  "$RUNTIME_APP"
fi
python3 "$PROJECT_DIR/scripts/verify-packaged-runtime-report.py" \
  --report "$EVIDENCE/runtime-verification.json" \
  --runtime-app "$RUNTIME_APP" \
  --evidence "$EVIDENCE" \
  --project-root "$PROJECT_DIR"
"$PROJECT_DIR/scripts/verify-runtime-compliance.sh" \
  "$COMPLIANCE" \
  "$EVIDENCE/fingerprint-chromium.lock.json"

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
