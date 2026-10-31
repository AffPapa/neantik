#!/bin/zsh

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PARENT="$(dirname "$PROJECT_DIR")"
export DEVELOPER_DIR="$(
  "$PROJECT_DIR/scripts/resolve-compatible-developer-dir.sh"
)"
SOURCE_APP="${1:-$PROJECT_DIR/dist/NeAntik-Integrated.app}"
CANDIDATE_APP="$PROJECT_DIR/dist/NeAntik.app"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"

# Only a registered owned location may replace the default candidate paths.
if [[ -n "${NEANTIK_DIRECT_CANDIDATE_ROOT:-}" ]]; then
  CANDIDATE_ROOT="$(python3 -I -B "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
    "$PROJECT_DIR/scripts/release_candidate_location.py" \
    --project-root "$PROJECT_DIR" --validate "$NEANTIK_DIRECT_CANDIDATE_ROOT")"
  CANDIDATE_APP="$CANDIDATE_ROOT/NeAntik.app"
  CANDIDATE_MANIFEST="$CANDIDATE_ROOT/direct-candidate-manifest.json"
fi

SOURCE_RUNTIME="$SOURCE_APP/Contents/Resources/NeAntik Browser.app"
CANDIDATE_RUNTIME="$CANDIDATE_APP/Contents/Resources/NeAntik Browser.app"
BUILD_SUPPORT_DIR="${NEANTIK_BUILD_SUPPORT_DIR:-/private/tmp/neantik-direct-manager-update}"
SECURITY_BASELINE_ARGS=()
PREPARATION_MODE="${NEANTIK_MANAGER_PREPARATION_MODE:-complete}"
case "${NEANTIK_CHROMIUM_ONLY:-0}" in
  0|1) ;;
  *) echo "NEANTIK_CHROMIUM_ONLY must be 0 or 1." >&2; exit 64 ;;
esac
case "$PREPARATION_MODE" in
  complete) ;;
  bundle-only)
    if [[ -z "${NEANTIK_DIRECT_CANDIDATE_ROOT:-}" || "${NEANTIK_LOCAL_ADHOC:-0}" != "0" ]]; then
      echo "Bundle-only preparation requires a registered Developer ID candidate." >&2
      exit 64
    fi
    ;;
  *) echo "Unknown manager preparation mode." >&2; exit 64 ;;
esac

# Keep one owner of the actual release cache, including direct script invocation.
if ! python3 -B "$PROJECT_DIR/scripts/native_cache_lock.py" --root "$BUILD_SUPPORT_DIR" --is-held; then
  exec python3 -B "$PROJECT_DIR/scripts/native_cache_lock.py" --root "$BUILD_SUPPORT_DIR" -- "$0" "$@"
fi


resolve_source_provenance() {
  local configured="${NEANTIK_SOURCE_PROVENANCE:-}"
  if [[ -n "$configured" ]]; then
    if [[ "$configured" != /* || ! -f "$configured" ]]; then
      echo "NEANTIK_SOURCE_PROVENANCE must point to an existing absolute file." >&2
      exit 66
    fi
    echo "$configured"
    return
  fi
  local packaged_version
  packaged_version="$(plutil -extract fingerprintChromium.chromiumVersion raw -o - \
    "$SOURCE_APP/Contents/Resources/NeAntikRuntimeEvidence/fingerprint-chromium.lock.json" \
    2>/dev/null || true)"
  if [[ "$packaged_version" == 154.* || "$packaged_version" == 155.* || "$packaged_version" == 156.* ]]; then
    echo "Chromium 154/155/156 manager-only preparation requires explicit NEANTIK_SOURCE_PROVENANCE from the exact qualified source build; refusing the historical M152 default." >&2
    exit 66
  fi
  local default="/private/tmp/nevision-chromium-152/build/source-provenance.json"
  if [[ -f "$default" ]]; then
    echo "$default"
    return
  fi
  echo "Missing runtime source provenance evidence." >&2
  echo "Set NEANTIK_SOURCE_PROVENANCE=/absolute/path/source-provenance.json." >&2
  exit 66
}

resolve_runtime_candidate_lock() {
  local configured="${NEANTIK_RUNTIME_CANDIDATE_LOCK:-}"
  if [[ -n "$configured" ]]; then
    if [[ "$configured" != /* || ! -f "$configured" ]]; then
      echo "NEANTIK_RUNTIME_CANDIDATE_LOCK must point to an existing absolute file." >&2
      exit 66
    fi
    echo "$configured"
    return
  fi
  local source_provenance
  source_provenance="$(resolve_source_provenance)"
  local default="$(dirname "$source_provenance")/runtime-candidate-lock.json"
  if [[ ! -f "$default" ]]; then
    "$PROJECT_DIR/scripts/export-runtime-candidate-lock.py" \
      "$source_provenance" \
      --output "$default"
  fi
  echo "$default"
}

verify_reviewed_runtime_evidence() {
  local evidence="$CANDIDATE_APP/Contents/Resources/NeAntikRuntimeEvidence"
  local compliance="$CANDIDATE_APP/Contents/Resources/NeAntikRuntimeCompliance"
  local source_provenance
  local runtime_candidate_lock
  local runtime_version
  local source_contract
  source_provenance="$(resolve_source_provenance)"
  runtime_candidate_lock="$(resolve_runtime_candidate_lock)"
  runtime_version="$(plutil -extract fingerprintChromium.chromiumVersion raw -o - \
    "$evidence/fingerprint-chromium.lock.json" 2>/dev/null || true)"
  case "$runtime_version" in
    153.*)
      source_contract="$PROJECT_DIR/runtime/chromium-153-port-status.json"
      ;;
    152.*)
      source_contract="$PROJECT_DIR/runtime/chromium-152-source-contract.json"
      ;;
    154.0.8037.93)
      source_contract="$PROJECT_DIR/runtime/chromium-154-source-contract.json"
      ;;
    154.0.8037.98)
      source_contract="$PROJECT_DIR/runtime/chromium-15498-source-contract.json"
      ;;
    155.0.8059.40)
      local variant_prefix
      variant_prefix="$(python3 "$PROJECT_DIR/scripts/chromium_15540_variant.py" "$evidence/fingerprint-chromium.lock.json")"
      source_contract="$PROJECT_DIR/runtime/${variant_prefix}-source-contract.json"
      ;;
    156.0.8078.12)
      local m156_prefix
      m156_prefix="$(python3 "$PROJECT_DIR/scripts/chromium_15612_variant.py" "$evidence/fingerprint-chromium.lock.json")"
      source_contract="$PROJECT_DIR/runtime/${m156_prefix}-source-contract.json"
      ;;
    156.0.8078.48)
      source_contract="$PROJECT_DIR/runtime/chromium-15648-source-contract.json"
      ;;
    156.0.8078.74)
      source_contract="$PROJECT_DIR/runtime/chromium-15674-source-contract.json"
      ;;
    156.0.8078.80)
      local m15680_variant
      m15680_variant="$(plutil -extract variant raw -o - "$evidence/fingerprint-chromium.lock.json" 2>/dev/null || true)"
      case "$m15680_variant" in
        recipient-privacy-policy-v1)
          source_contract="$PROJECT_DIR/runtime/chromium-15680-privacy-v1-source-contract.json"
          ;;
        "")
          source_contract="$PROJECT_DIR/runtime/chromium-15680-source-contract.json"
          ;;
        *)
          echo "Unsupported Chromium 156.80 runtime variant for manager-only update." >&2
          exit 65
          ;;
      esac
      ;;
    *)
      echo "Unsupported Chromium runtime version for manager-only update: $runtime_version" >&2
      exit 65
      ;;
  esac
  local packaged_contract_name="$(basename "$source_contract")"
  if [[ "$runtime_version" == "154.0.8037.98" ]]; then
    packaged_contract_name="chromium-154-source-contract.json"
  fi

  local comparisons=(
    "$source_provenance:$evidence/source-provenance.json"
    "$runtime_candidate_lock:$evidence/fingerprint-chromium.lock.json"
    "$PROJECT_DIR/runtime/security-baseline.json:$evidence/release-security-baseline.json"
    "$PROJECT_DIR/runtime/nevision-patches/series.json:$evidence/neantik-patch-series.json"
    "$PROJECT_DIR/runtime/apple-device-tuples.json:$evidence/apple-device-tuples.json"
    "$source_contract:$evidence/$packaged_contract_name"
  )
  if [[ "$runtime_version" == "154.0.8037.93" ]]; then
    comparisons+=(
      "$PROJECT_DIR/runtime/chromium-154-device-memory-hotfix.json:$evidence/chromium-154-device-memory-hotfix.json"
      "$PROJECT_DIR/runtime/chromium-154-posthotfix-source-snapshot.json:$evidence/chromium-154-posthotfix-source-snapshot.json"
    )
  elif [[ "$runtime_version" == "154.0.8037.98" ]]; then
    local name
    for name in chromium-15498-source-input-manifest.json chromium-15498-source-snapshot.json chromium-15498-rebase-plan.json; do
      comparisons+=("$PROJECT_DIR/runtime/$name:$evidence/$name")
    done
    for name in device-memory-hotfix.json external-build-inputs.json ordered-patch-replay.json port-compatibility.json; do
      comparisons+=("$PROJECT_DIR/runtime/chromium-15498-source-evidence/$name:$evidence/chromium-15498-source-evidence/$name")
    done
  elif [[ "$runtime_version" == "155.0.8059.40" ]]; then
    python3 "$PROJECT_DIR/scripts/chromium_15540_packaged_evidence.py" \
      "$evidence/fingerprint-chromium.lock.json" "$evidence"
    local name
    for name in chromium-15540-source-input-manifest.json chromium-15540-source-snapshot.json chromium-15540-rebase-plan.json; do
      comparisons+=("$PROJECT_DIR/runtime/$name:$evidence/$name")
    done
    for name in ordered-patch-replay.json reviewed-source-overlay.json overlay-applied.json partial-port-decisions.json upstream-superseded-decisions.json pruning.json domain-substitution.json domain-substitution-inventory.json pinned-build-inputs.json generated-deps-hooks.json port-compatibility.json deps-revisions.json; do
      comparisons+=("$PROJECT_DIR/runtime/chromium-15540-source-evidence/$name:$evidence/chromium-15540-source-evidence/$name")
    done
  elif [[ "$runtime_version" == "156.0.8078.12" ]]; then
    python3 "$PROJECT_DIR/scripts/chromium_15612_packaged_evidence.py" \
      "$evidence/fingerprint-chromium.lock.json" "$evidence"
  elif [[ "$runtime_version" == "156.0.8078.48" ]]; then
    local name
    for name in chromium-15648-source-adoption-v3.json chromium-15648-deps-lock.json chromium-15648-neantik-v3.patch chromium-15648-devtools-typescript6.patch chromium-15648-v8-scope-iterator-compat.patch chromium-15648-rebase-plan.json; do
      comparisons+=("$PROJECT_DIR/runtime/$name:$evidence/chromium-15648-source-evidence/$name")
    done
  elif [[ "$runtime_version" == "156.0.8078.74" ]]; then
    local name
    for name in chromium-15674-source-adoption-v1.json chromium-15674-deps-lock.json chromium-15674-neantik.patch chromium-15674-devtools-typescript6.patch chromium-15674-v8-scope-iterator-compat.patch chromium-15674-rebase-plan.json chromium-15674-build-evidence.json chromium-15674-args.gn; do
      comparisons+=("$PROJECT_DIR/runtime/$name:$evidence/chromium-15674-source-evidence/$name")
    done
  fi
  local comparison
  for comparison in "${comparisons[@]}"; do
    local expected="${comparison%%:*}"
    local packaged="${comparison#*:}"
    if [[ ! -f "$expected" || -L "$expected" ||
          ! -f "$packaged" || -L "$packaged" ]] ||
       ! cmp -s "$expected" "$packaged"; then
      echo "Packaged runtime evidence does not match reviewed input: $packaged" >&2
      exit 65
    fi
  done

  "$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" \
    "$evidence/source-provenance.json"
  "$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
    "$evidence/fingerprint-chromium.lock.json" \
    "$evidence/source-provenance.json"
  python3 "$PROJECT_DIR/scripts/verify-packaged-runtime-report.py" \
    --report "$evidence/runtime-verification.json" \
    --runtime-app "$CANDIDATE_RUNTIME" \
    --evidence "$evidence" \
    --project-root "$PROJECT_DIR"
  "$PROJECT_DIR/scripts/verify-runtime-compliance.sh" \
    "$compliance" \
    "$evidence/fingerprint-chromium.lock.json"
}

verify_runtime_unchanged() {
  local source_manifest
  local candidate_manifest
  source_manifest="$(mktemp -t neantik-source-runtime-manifest)"
  candidate_manifest="$(mktemp -t neantik-candidate-runtime-manifest)"
  (
    cd "$SOURCE_RUNTIME"
    find -P . -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 shasum -a 256
    find -P . -type l -print0 |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' link; do
        printf 'link %s -> %s\n' "$link" "$(readlink "$link")"
      done
  ) >"$source_manifest"
  (
    cd "$CANDIDATE_RUNTIME"
    find -P . -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 shasum -a 256
    find -P . -type l -print0 |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' link; do
        printf 'link %s -> %s\n' "$link" "$(readlink "$link")"
      done
  ) >"$candidate_manifest"
  if ! cmp -s "$source_manifest" "$candidate_manifest"; then
    echo "Bundled Chromium changed while preparing the manager-only update." >&2
    exit 65
  fi
}

if [[ "$SOURCE_APP" != /* || ! -d "$SOURCE_APP" ]]; then
  echo "Source integrated app must be an existing absolute path." >&2
  exit 66
fi
if [[ -e "$CANDIDATE_MANIFEST" || -L "$CANDIDATE_MANIFEST" ]]; then
  echo "Prepared candidate manifest already exists; refusing to replace it." >&2
  echo "Archive or move this generated manifest before preparing a new candidate:" >&2
  echo "$CANDIDATE_MANIFEST" >&2
  exit 65
fi
case "${NEANTIK_RELEASE_CHANNEL:-}" in
  public-alpha)
    SECURITY_BASELINE_ARGS+=(--allow-public-alpha-tuples)
    ;;
  production)
    if [[ "$PREPARATION_MODE" == "bundle-only" ]]; then
      SECURITY_BASELINE_ARGS+=(--allow-unqualified-bundle)
    fi
    ;;
  *)
    echo "Set NEANTIK_RELEASE_CHANNEL to public-alpha or production." >&2
    exit 64
    ;;
esac
source "$PROJECT_DIR/scripts/resolve-webkit-proxy-build-mode.sh"
WEBKIT_HOST_ENABLED="${NEANTIK_WEBKIT_HOST_ENABLED:-0}"
case "$WEBKIT_HOST_ENABLED" in
  0|1) ;;
  *) echo "NEANTIK_WEBKIT_HOST_ENABLED must be 0 or 1." >&2; exit 64 ;;
esac
if [[ "${NEANTIK_CHROMIUM_ONLY:-0}" == "1" && "$WEBKIT_HOST_ENABLED" == "1" ]]; then
  echo "Chromium-only manager cannot include the owned WebKit host." >&2
  exit 78
fi
if [[ "${NEANTIK_RELEASE_CHANNEL:-}" == "production" ]]; then
  if [[ "$WEBKIT_HOST_ENABLED" != "1" ]]; then
    echo "Production release requires the owned WebKit host; refusing a proxy-enabled manager-only candidate." >&2
    exit 78
  fi
  if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ||
        "${NEANTIK_WEBKIT_BUILD_ROOT:-}" != /* ||
        "${NEANTIK_WEBKIT_SOURCE_ROOT:-}" != /* ||
        "${NEANTIK_WEBKIT_BUILD_RECEIPT:-}" != /* ||
        "${NEANTIK_WEBKIT_SOURCE_OFFER_ROOT:-}" != /* ||
        ! -d "${NEANTIK_WEBKIT_BUILD_ROOT:-/nonexistent}" ||
        ! -d "${NEANTIK_WEBKIT_SOURCE_ROOT:-/nonexistent}" ||
        ! -f "${NEANTIK_WEBKIT_BUILD_RECEIPT:-/nonexistent}" ||
        ! -d "${NEANTIK_WEBKIT_SOURCE_OFFER_ROOT:-/nonexistent}" ]]; then
    echo "Production WebKit packaging requires pinned physical build/source roots, exact build receipt, source offer and Developer ID signing." >&2
    exit 78
  fi
elif [[ "$WEBKIT_HOST_ENABLED" == "1" ]]; then
  echo "Owned WebKit release packaging requires NEANTIK_RELEASE_CHANNEL=production." >&2
  exit 64
fi
if [[ "${NEANTIK_LOCAL_ADHOC:-0}" != "1" ]]; then
  : "${NEANTIK_SIGNING_IDENTITY:?Set NEANTIK_SIGNING_IDENTITY to a Developer ID Application identity}"
  python3 "$PROJECT_DIR/scripts/direct_backup_signing.py" preflight "$SOURCE_APP" "$NEANTIK_SIGNING_IDENTITY"
fi
runtime_candidate_lock="$(resolve_runtime_candidate_lock)"

"$PROJECT_DIR/scripts/verify-runtime-security-baseline.py" \
  --lock "$runtime_candidate_lock" \
  "${SECURITY_BASELINE_ARGS[@]}"
"$PROJECT_DIR/scripts/verify-runtime-security-reference.py"
"$PROJECT_DIR/scripts/verify-direct-version-bump.py"
"$PROJECT_DIR/scripts/verify-direct-telemetry-disabled.py"
"$PROJECT_DIR/scripts/verify-direct-update-policy.py"
"$PROJECT_DIR/scripts/verify-public-fingerprint-corpus.py"
"$PROJECT_DIR/scripts/verify-direct-ui-localization.py"
codesign --verify --deep --strict --verbose=2 "$SOURCE_APP"

mkdir -p \
  "$BUILD_SUPPORT_DIR/clang" \
  "$BUILD_SUPPORT_DIR/swiftpm" \
  "$BUILD_SUPPORT_DIR/cache" \
  "$BUILD_SUPPORT_DIR/config" \
  "$BUILD_SUPPORT_DIR/security"
export CLANG_MODULE_CACHE_PATH="$BUILD_SUPPORT_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_SUPPORT_DIR/swiftpm"

if [[ "$PREPARATION_MODE" == "bundle-only" ]]; then
  python3 -B "$PROJECT_DIR/scripts/prepared_manager_bundle.py" begin --project-root "$PROJECT_DIR" --root "$CANDIDATE_ROOT"
fi
cd "$PROJECT_DIR"
swift build \
  --build-system native \
  --jobs 2 \
  -c release \
  --arch arm64 \
  --disable-sandbox \
  --scratch-path "$BUILD_SUPPORT_DIR/swift-build" \
  --cache-path "$BUILD_SUPPORT_DIR/cache" \
  --config-path "$BUILD_SUPPORT_DIR/config" \
  --security-path "$BUILD_SUPPORT_DIR/security" \
  -Xswiftc -debug-prefix-map \
  -Xswiftc "$PROJECT_DIR=/NeAntikSource" \
  -Xswiftc -debug-prefix-map \
  -Xswiftc "$SOURCE_PARENT=/NeAntikWorkspace" \
  -Xswiftc -file-prefix-map \
  -Xswiftc "$PROJECT_DIR=/NeAntikSource" \
  -Xswiftc -file-prefix-map \
  -Xswiftc "$SOURCE_PARENT=/NeAntikWorkspace" \
  -Xcc "-fdebug-prefix-map=$PROJECT_DIR=/NeAntikSource" \
  -Xcc "-fdebug-prefix-map=$SOURCE_PARENT=/NeAntikWorkspace"

BIN_PATH="$(
  swift build \
  --build-system native \
    --jobs 2 \
    -c release \
    --arch arm64 \
    --disable-sandbox \
    --scratch-path "$BUILD_SUPPORT_DIR/swift-build" \
    --cache-path "$BUILD_SUPPORT_DIR/cache" \
    --config-path "$BUILD_SUPPORT_DIR/config" \
    --security-path "$BUILD_SUPPORT_DIR/security" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$PROJECT_DIR=/NeAntikSource" \
    -Xswiftc -debug-prefix-map \
    -Xswiftc "$SOURCE_PARENT=/NeAntikWorkspace" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$PROJECT_DIR=/NeAntikSource" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$SOURCE_PARENT=/NeAntikWorkspace" \
    -Xcc "-fdebug-prefix-map=$PROJECT_DIR=/NeAntikSource" \
    -Xcc "-fdebug-prefix-map=$SOURCE_PARENT=/NeAntikWorkspace" \
    --show-bin-path
)"
if [[ ! -d "$BIN_PATH" || -L "$BIN_PATH" ]]; then
  echo "Swift build output path must resolve to a physical directory." >&2
  exit 66
fi
BIN_PATH="$(cd "$BIN_PATH" && pwd -P)"
MANAGER_BINARY="$BIN_PATH/NeAntik"
if [[ ! -x "$MANAGER_BINARY" ]]; then
  echo "Swift release binary is missing: $MANAGER_BINARY" >&2
  exit 70
fi

if [[ -n "${NEANTIK_DIRECT_CANDIDATE_ROOT:-}" && (-e "$CANDIDATE_APP" || -L "$CANDIDATE_APP") ]]; then
  echo "Registered candidate already exists; refusing replacement. Create a new location." >&2
  exit 65
fi

# Recheck at the destructive boundary: a launch may have happened during
# compilation, including when this preparation script is called directly.
if [[ -e "$CANDIDATE_APP" ]]; then
  python3 "$PROJECT_DIR/scripts/wait-for-neantik-runtime-drain.py" \
    --app "$CANDIDATE_APP" --timeout 2
fi
rm -rf "$CANDIDATE_APP"
ditto --norsrc "$SOURCE_APP" "$CANDIDATE_APP"
cp "$MANAGER_BINARY" "$CANDIDATE_APP/Contents/MacOS/NeAntik"
python3 "$PROJECT_DIR/scripts/sanitize-manager-rpaths.py" "$CANDIDATE_APP/Contents/MacOS/NeAntik"
# SwiftPM can retain DWARF source/object paths even with prefix maps. Match
# package-app.sh: strip only manager debug sections before its public signature.
xcrun strip -S "$CANDIDATE_APP/Contents/MacOS/NeAntik"
cp "$PROJECT_DIR/Resources/Info.plist" \
  "$CANDIDATE_APP/Contents/Info.plist"
if [[ "${NEANTIK_CHROMIUM_ONLY:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy \
    -c 'Add :NeAntikEngineScope string chromium-only' \
    "$CANDIDATE_APP/Contents/Info.plist"
fi
if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ]]; then
  python3 "$PROJECT_DIR/scripts/package-update-helpers.py" "$CANDIDATE_APP" "$BIN_PATH" -
else
  python3 "$PROJECT_DIR/scripts/package-update-helpers.py" "$CANDIDATE_APP" "$BIN_PATH" "$NEANTIK_SIGNING_IDENTITY"
fi
cp "$PROJECT_DIR/Resources/NeAntik.icns" \
  "$CANDIDATE_APP/Contents/Resources/NeAntik.icns"
cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" \
  "$CANDIDATE_APP/Contents/Resources/PrivacyInfo.xcprivacy"
mkdir -p "$CANDIDATE_APP/Contents/Resources/ru.lproj"
cp \
  "$PROJECT_DIR/Resources/ru.lproj/InfoPlist.strings" \
  "$PROJECT_DIR/Resources/ru.lproj/Localizable.strings" \
  "$CANDIDATE_APP/Contents/Resources/ru.lproj/"
printf 'APPLNANT' >"$CANDIDATE_APP/Contents/PkgInfo"
rm -rf "$CANDIDATE_APP/Contents/_CodeSignature"
python3 "$PROJECT_DIR/scripts/package-manager-release-baseline.py" \
  --project-root "$PROJECT_DIR" \
  --evidence "$CANDIDATE_APP/Contents/Resources/NeAntikRuntimeEvidence" \
  --inherited-evidence "$SOURCE_APP/Contents/Resources/NeAntikRuntimeEvidence"
verify_reviewed_runtime_evidence

verify_runtime_unchanged
if [[ "$(plutil -extract fingerprintChromium.chromiumVersion raw -o - "$CANDIDATE_APP/Contents/Resources/NeAntikRuntimeEvidence/fingerprint-chromium.lock.json")" == "156.0.8078.12" ]]; then
  python3 "$PROJECT_DIR/scripts/verify-direct-update-runtime-pins.py" --reference-app "$CANDIDATE_APP"
fi

if [[ "$WEBKIT_HOST_ENABLED" == "1" ]]; then
  python3 "$PROJECT_DIR/scripts/package-owned-webkit-release.py" \
    --app "$CANDIDATE_APP" \
    --build-root "$NEANTIK_WEBKIT_BUILD_ROOT" \
    --source-root "$NEANTIK_WEBKIT_SOURCE_ROOT" \
    --build-receipt "$NEANTIK_WEBKIT_BUILD_RECEIPT" \
    --source-offer-root "$NEANTIK_WEBKIT_SOURCE_OFFER_ROOT" \
    --source-offer-manifest-sha256 "${NEANTIK_WEBKIT_SOURCE_OFFER_MANIFEST_SHA256:?Set the frozen corresponding-source manifest SHA-256}" \
    --identity "$NEANTIK_SIGNING_IDENTITY"
fi

if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ]]; then
  if [[ "${NEANTIK_BROWSER_DATA_BACKUP_ENABLED:-0}" != "0" || -n "${NEANTIK_DIRECT_PROVISIONING_PROFILE:-}" ]]; then
    echo "Local QA signing cannot enable production backup." >&2
    exit 65
  fi
  echo "LOCAL QA ONLY: applying an ad-hoc outer signature."
  codesign \
    --force \
    --options runtime \
    --sign - \
    "$CANDIDATE_APP"
else
  python3 "$PROJECT_DIR/scripts/direct_backup_signing.py" sign "$CANDIDATE_APP" "$NEANTIK_SIGNING_IDENTITY"
fi
codesign --verify --deep --strict --verbose=2 "$CANDIDATE_APP"

verify_runtime_unchanged
python3 "$PROJECT_DIR/scripts/verify-public-artifact-privacy.py" "$CANDIDATE_APP"

"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$CANDIDATE_APP"
"$PROJECT_DIR/scripts/verify-direct-branding-residue.py" \
  --app "$CANDIDATE_APP" \
  --allow-legacy-runtime-branding
if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ]]; then
  echo "LOCAL QA ONLY: schema-3 release enrollment was intentionally skipped."
  echo "$CANDIDATE_APP"
  exit 0
fi
PRIVATE_RELEASE_BASE="$PROJECT_DIR/dist/private"
if [[ "$PREPARATION_MODE" == "bundle-only" ]]; then
  python3 -B "$PROJECT_DIR/scripts/prepared_manager_bundle.py" finish --project-root "$PROJECT_DIR" --root "$CANDIDATE_ROOT"
  echo "Signed bundle prepared; native qualification and publication remain pending."
  exit 0
fi
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
  "$CANDIDATE_APP" \
  "$FINGERPRINT_ENROLLMENT"
codesign --verify --deep --strict --verbose=2 "$CANDIDATE_APP"
verify_runtime_unchanged
python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" create \
  --app "$CANDIDATE_APP" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL" \
  --fingerprint-enrollment "$FINGERPRINT_ENROLLMENT"

echo "$CANDIDATE_APP"
echo "$CANDIDATE_MANIFEST"
echo "Next: run a fresh GUI A → B → A report with this app, then notarize."
