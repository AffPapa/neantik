#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
REPORT_PATH="$PROJECT_DIR/dist/fingerprint-audit.json"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
ARCHIVE_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
NOTARY_LOG_DIR="$PROJECT_DIR/dist/notary"
SECURITY_BASELINE_ARGS=()
GUI_QUALIFICATION_ARGS=()

: "${NEANTIK_NOTARY_PROFILE:?Set NEANTIK_NOTARY_PROFILE to a notarytool Keychain profile}"
case "${NEANTIK_RELEASE_CHANNEL:-}" in
  public-alpha)
    SECURITY_BASELINE_ARGS+=(--allow-public-alpha-tuples)
    ;;
  production)
    GUI_QUALIFICATION_ARGS+=(--require-production)
    ;;
  *)
    echo "Set NEANTIK_RELEASE_CHANNEL to public-alpha or production." >&2
    exit 64
    ;;
esac
if [[ ! -d "$APP_PATH" || ! -f "$REPORT_PATH" ||
      ! -f "$CANDIDATE_MANIFEST" || -L "$CANDIDATE_MANIFEST" ]]; then
  echo "Prepared NeAntik.app, its manifest and fresh fingerprint-audit.json are required." >&2
  exit 66
fi
SUMMARY_PATH="$PROJECT_DIR/dist/fingerprint-audit-summary.json"
if [[ ! -f "$SUMMARY_PATH" || -L "$SUMMARY_PATH" ]]; then
  echo "Fresh public-safe fingerprint attestation is required." >&2
  exit 66
fi
if [[ -e "$ARCHIVE_PATH" || -e "$CHECKSUM_PATH" ]]; then
  echo "Candidate archive or checksum already exists; refusing overwrite." >&2
  exit 65
fi

python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL" \
  --fingerprint-evidence "$REPORT_PATH"
"$PROJECT_DIR/scripts/verify-runtime-security-baseline.py" \
  --lock \
  "$APP_PATH/Contents/Resources/NeAntikRuntimeEvidence/fingerprint-chromium.lock.json" \
  "${SECURITY_BASELINE_ARGS[@]}"
"$PROJECT_DIR/scripts/verify-runtime-security-reference.py"
"$PROJECT_DIR/scripts/verify-direct-telemetry-disabled.py"
"$PROJECT_DIR/scripts/verify-direct-update-policy.py"
"$PROJECT_DIR/scripts/verify-public-fingerprint-corpus.py"
python3 "$PROJECT_DIR/scripts/verify-gui-fingerprint-report.py" \
  "$REPORT_PATH" \
  --integrated-app "$APP_PATH" \
  "${GUI_QUALIFICATION_ARGS[@]}"
python3 "$PROJECT_DIR/scripts/verify-public-artifact-privacy.py" \
  "$SUMMARY_PATH" \
  --private-evidence "$REPORT_PATH" \
  --attestation "$SUMMARY_PATH" \
  --integrated-app "$APP_PATH" \
  --candidate-manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL"
"$PROJECT_DIR/scripts/verify-integrated-release.sh" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_DETAILS="$(codesign -dvvv "$APP_PATH" 2>&1)"
if ! grep -Fq "Authority=Developer ID Application:" \
  <<<"$SIGNATURE_DETAILS"; then
  echo "Candidate is not signed with Developer ID Application." >&2
  exit 65
fi
if ! grep -Fq "Timestamp=" <<<"$SIGNATURE_DETAILS"; then
  echo "Candidate does not contain a secure signing timestamp." >&2
  exit 65
fi

ditto --norsrc -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
mkdir -p "$NOTARY_LOG_DIR"
SUBMIT_LOG="$NOTARY_LOG_DIR/$(basename "$ARCHIVE_PATH").notary-submit.log"
xcrun notarytool submit \
  "$ARCHIVE_PATH" \
  --keychain-profile "$NEANTIK_NOTARY_PROFILE" \
  --wait 2>&1 | tee "$SUBMIT_LOG"
if ! grep -Eq '^[[:space:]]*status:[[:space:]]*Accepted[[:space:]]*$' \
  "$SUBMIT_LOG"; then
  echo "Apple notarization did not accept the candidate." >&2
  exit 65
fi

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"
python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL" \
  --fingerprint-evidence "$REPORT_PATH"

rm -f "$ARCHIVE_PATH"
ditto --norsrc -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
if unzip -Z1 "$ARCHIVE_PATH" |
  grep -Eq '(^|/)__MACOSX/|(^|/)\.DS_Store$|(^|/)\._[^/]+$'; then
  echo "Direct release archive contains forbidden Finder metadata." >&2
  exit 65
fi
(
  cd "$(dirname "$ARCHIVE_PATH")"
  shasum -a 256 "$(basename "$ARCHIVE_PATH")"
) >"$CHECKSUM_PATH"

"$PROJECT_DIR/scripts/verify-direct-notarized-archive.py"
echo "$ARCHIVE_PATH"
echo "$CHECKSUM_PATH"
