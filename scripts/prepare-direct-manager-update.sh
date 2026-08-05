#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${1:-$PROJECT_DIR/dist/NeAntik-Integrated.app}"
CANDIDATE_APP="$PROJECT_DIR/dist/NeAntik.app"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
SOURCE_RUNTIME="$SOURCE_APP/Contents/Resources/NeAntik Browser.app"
CANDIDATE_RUNTIME="$CANDIDATE_APP/Contents/Resources/NeAntik Browser.app"
BUILD_SUPPORT_DIR="${NEANTIK_BUILD_SUPPORT_DIR:-/private/tmp/neantik-direct-manager-update}"
SECURITY_BASELINE_ARGS=()

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
  local default="/private/tmp/nevision-chromium-151/build/source-provenance.json"
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

copy_reviewed_runtime_evidence() {
  local evidence="$CANDIDATE_APP/Contents/Resources/NeAntikRuntimeEvidence"
  local source_provenance
  local runtime_candidate_lock
  source_provenance="$(resolve_source_provenance)"
  runtime_candidate_lock="$(resolve_runtime_candidate_lock)"
  mkdir -p "$evidence"
  cp "$runtime_candidate_lock" "$evidence/fingerprint-chromium.lock.json"
  cp "$PROJECT_DIR/runtime/security-baseline.json" \
    "$evidence/security-baseline.json"
  cp "$PROJECT_DIR/runtime/nevision-patches/series.json" \
    "$evidence/neantik-patch-series.json"
  cp "$PROJECT_DIR/runtime/apple-device-tuples.json" \
    "$evidence/apple-device-tuples.json"
  cp "$PROJECT_DIR/runtime/chromium-151-source-contract.json" \
    "$evidence/chromium-151-source-contract.json"
  cp "$source_provenance" "$evidence/source-provenance.json"
  "$PROJECT_DIR/scripts/verify-runtime-source-provenance.py" \
    "$evidence/source-provenance.json"
  "$PROJECT_DIR/scripts/verify-runtime-candidate-lock.py" \
    "$evidence/fingerprint-chromium.lock.json" \
    "$evidence/source-provenance.json"
  "$PROJECT_DIR/scripts/verify-built-runtime.sh" \
    "$CANDIDATE_RUNTIME" \
    "$evidence/runtime-verification.json" \
    "$evidence/args.gn" \
    "$evidence/source-provenance.json" \
    "$evidence/fingerprint-chromium.lock.json"
}

rebind_runtime_compliance() {
  local compliance="$CANDIDATE_APP/Contents/Resources/NeAntikRuntimeCompliance"
  local lock="$CANDIDATE_APP/Contents/Resources/NeAntikRuntimeEvidence/fingerprint-chromium.lock.json"
  COMPLIANCE_DIR="$compliance" LOCK_FILE="$lock" python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

root = Path(os.environ["COMPLIANCE_DIR"])
lock = Path(os.environ["LOCK_FILE"])
manifest_path = root / "compliance-manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
spdx_meta = manifest.get("spdx")
if not isinstance(spdx_meta, dict):
    raise SystemExit("Compliance SPDX metadata is missing.")
spdx_path = root / str(spdx_meta.get("file", ""))
if not spdx_path.is_file():
    raise SystemExit("Compliance SPDX document is missing.")
spdx = json.loads(spdx_path.read_text(encoding="utf-8"))
lock_sha = sha256(lock)
version = manifest.get("chromiumVersion")
namespace = f"https://neantik.app/spdx/chromium-{version}-{lock_sha}"
spdx["documentNamespace"] = namespace
spdx_path.write_text(
    json.dumps(spdx, indent=4, sort_keys=False) + "\n",
    encoding="utf-8",
)
manifest["sourceLockSHA256"] = lock_sha
spdx_meta["documentNamespace"] = namespace
spdx_meta["sha256"] = sha256(spdx_path)
manifest_path.write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  "$PROJECT_DIR/scripts/verify-runtime-compliance.sh" "$compliance" "$lock"
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
    ;;
  *)
    echo "Set NEANTIK_RELEASE_CHANNEL to public-alpha or production." >&2
    exit 64
    ;;
esac
if [[ "${NEANTIK_LOCAL_ADHOC:-0}" != "1" ]]; then
  : "${NEANTIK_SIGNING_IDENTITY:?Set NEANTIK_SIGNING_IDENTITY to a Developer ID Application identity}"
fi

"$PROJECT_DIR/scripts/verify-runtime-security-baseline.py" \
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

cd "$PROJECT_DIR"
swift build \
  -c release \
  --arch arm64 \
  --disable-sandbox \
  --cache-path "$BUILD_SUPPORT_DIR/cache" \
  --config-path "$BUILD_SUPPORT_DIR/config" \
  --security-path "$BUILD_SUPPORT_DIR/security"

rm -rf "$CANDIDATE_APP"
ditto --norsrc "$SOURCE_APP" "$CANDIDATE_APP"
cp "$PROJECT_DIR/.build/arm64-apple-macosx/release/NeAntik" \
  "$CANDIDATE_APP/Contents/MacOS/NeAntik"
cp "$PROJECT_DIR/Resources/Info.plist" \
  "$CANDIDATE_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/NeAntik.icns" \
  "$CANDIDATE_APP/Contents/Resources/NeAntik.icns"
cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" \
  "$CANDIDATE_APP/Contents/Resources/PrivacyInfo.xcprivacy"
printf 'APPLNANT' >"$CANDIDATE_APP/Contents/PkgInfo"
rm -rf "$CANDIDATE_APP/Contents/_CodeSignature"
copy_reviewed_runtime_evidence
rebind_runtime_compliance

verify_runtime_unchanged

if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ]]; then
  echo "LOCAL QA ONLY: applying an ad-hoc outer signature."
  codesign \
    --force \
    --options runtime \
    --sign - \
    "$CANDIDATE_APP"
else
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$NEANTIK_SIGNING_IDENTITY" \
    "$CANDIDATE_APP"
fi
codesign --verify --deep --strict --verbose=2 "$CANDIDATE_APP"

verify_runtime_unchanged

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
