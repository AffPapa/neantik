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
python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" create \
  --app "$CANDIDATE_APP" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL"

echo "$CANDIDATE_APP"
echo "$CANDIDATE_MANIFEST"
echo "Next: run a fresh GUI A → B → A report with this app, then notarize."
