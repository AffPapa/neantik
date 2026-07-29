#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINEERING_APP_PATH="$PROJECT_DIR/dist/NeAntik-Integrated.app"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
ARCHIVE_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
NOTARY_LOG_DIR="$PROJECT_DIR/dist/notary"

verify_zip_has_no_finder_metadata() {
  local archive="$1"
  if unzip -Z1 "$archive" |
    grep -Eq '(^|/)__MACOSX/|(^|/)\.DS_Store$|(^|/)\._[^/]+$'; then
    echo "Direct release archive contains forbidden Finder metadata." >&2
    exit 65
  fi
}

submit_notarization() {
  local archive="$1"
  local submit_log="$NOTARY_LOG_DIR/$(basename "$archive").notary-submit.log"
  local submission_id=""
  local notary_status=""
  local notary_log=""

  mkdir -p "$NOTARY_LOG_DIR"
  rm -f "$submit_log"

  xcrun notarytool submit \
    "$archive" \
    --keychain-profile "$NEANTIK_NOTARY_PROFILE" \
    --wait 2>&1 | tee "$submit_log"

  submission_id="$(
    awk '/^[[:space:]]*id:/ {print $2}' "$submit_log" | tail -n 1
  )"
  notary_status="$(
    awk '/^[[:space:]]*status:/ {print $2}' "$submit_log" | tail -n 1
  )"

  if [[ "$notary_status" != "Accepted" ]]; then
    echo "Apple notarization did not accept the archive. Status: ${notary_status:-unknown}" >&2
    echo "Notary submit log: $submit_log" >&2

    if [[ -n "$submission_id" ]]; then
      notary_log="$NOTARY_LOG_DIR/$submission_id.notary-log.json"
      echo "Fetching Apple notary diagnostic log: $submission_id" >&2
      if xcrun notarytool log \
        "$submission_id" \
        --keychain-profile "$NEANTIK_NOTARY_PROFILE" \
        "$notary_log"
      then
        echo "Apple notary diagnostic log: $notary_log" >&2
        cat "$notary_log" >&2
      else
        echo "Could not fetch Apple notary diagnostic log." >&2
      fi
    fi

    exit 65
  fi
}

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 /absolute/path/to/NeAntik\\ Browser.app /absolute/path/to/args.gn /absolute/path/to/chromium/src" >&2
  exit 64
fi

RUNTIME_APP="$1"
BUILD_ARGS="$2"
SOURCE_ROOT="$3"
for input in "$RUNTIME_APP" "$BUILD_ARGS" "$SOURCE_ROOT"; do
  if [[ "$input" != /* || ! -e "$input" ]]; then
    echo "Direct release inputs must be existing absolute paths: $input" >&2
    exit 66
  fi
done

SECURITY_BASELINE_ARGS=()
if [[ "${NEANTIK_RELEASE_CHANNEL:-}" == "public-alpha" ]]; then
  SECURITY_BASELINE_ARGS+=(--allow-public-alpha-tuples)
fi
"$PROJECT_DIR/scripts/verify-runtime-security-baseline.py" "${SECURITY_BASELINE_ARGS[@]}"
"$PROJECT_DIR/scripts/verify-direct-version-bump.py"
"$PROJECT_DIR/scripts/verify-direct-telemetry-disabled.py"

: "${NEANTIK_SIGNING_IDENTITY:?Set NEANTIK_SIGNING_IDENTITY to a Developer ID Application identity}"
: "${NEANTIK_NOTARY_PROFILE:?Set NEANTIK_NOTARY_PROFILE to an xcrun notarytool Keychain profile}"
: "${NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL:?Set NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL to the final public HTTPS download URL for $ARCHIVE_PATH}"

PACKAGING_DIR="$(dirname "$RUNTIME_APP")/NeAntik Browser Packaging"
SIGNED_RUNTIME_ROOT="$(mktemp -d -t nevision-developer-id-runtime)"
SIGNED_RUNTIME="$SIGNED_RUNTIME_ROOT/NeAntik Browser.app"
cleanup() {
  rm -rf "$SIGNED_RUNTIME_ROOT"
}
trap cleanup EXIT

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
  echo "Public Direct release requires one explicit angle_enable_metal=true declaration." >&2
  exit 65
fi

cd "$PROJECT_DIR"

"$PROJECT_DIR/scripts/preflight-distribution.sh" direct
export NEANTIK_CHROMIUM_SOURCE_ROOT="$SOURCE_ROOT"
"$PROJECT_DIR/scripts/sign-runtime.sh" \
  "$RUNTIME_APP" \
  "$PACKAGING_DIR" \
  "$SIGNED_RUNTIME"
"$PROJECT_DIR/scripts/package-integrated-app.sh" \
  "$SIGNED_RUNTIME" \
  "$BUILD_ARGS" \
  "$SOURCE_ROOT"
rm -rf "$APP_PATH"
ditto "$ENGINEERING_APP_PATH" "$APP_PATH"

codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$NEANTIK_SIGNING_IDENTITY" \
  "$APP_PATH"

SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
printf '%s\n' "$SIGNATURE_DETAILS"
if ! printf '%s\n' "$SIGNATURE_DETAILS" |
    grep -Eq '^CodeDirectory .*flags=.*runtime'; then
  echo "Direct release is missing the hardened runtime signature flag." >&2
  exit 65
fi
if ! printf '%s\n' "$SIGNATURE_DETAILS" |
    grep -q '^Authority=Developer ID Application:'; then
  echo "Direct release is not signed by Developer ID Application." >&2
  exit 65
fi
if ! printf '%s\n' "$SIGNATURE_DETAILS" |
    grep -q '^Timestamp='; then
  echo "Direct release is missing a trusted signing timestamp." >&2
  exit 65
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$APP_PATH"

ditto --norsrc -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
verify_zip_has_no_finder_metadata "$ARCHIVE_PATH"

submit_notarization "$ARCHIVE_PATH"

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

ditto --norsrc -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
verify_zip_has_no_finder_metadata "$ARCHIVE_PATH"
(
  cd "$(dirname "$ARCHIVE_PATH")"
  shasum -a 256 "$(basename "$ARCHIVE_PATH")"
) >"$CHECKSUM_PATH"

"$PROJECT_DIR/scripts/verify-direct-notarized-archive.py"

echo "$ARCHIVE_PATH"
echo "$CHECKSUM_PATH"
echo "Next: upload the versioned archive to a draft GitHub Release, verify the downloaded asset, then publish the release."
