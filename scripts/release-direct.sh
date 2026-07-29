#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
ARCHIVE_PATH="$PROJECT_DIR/dist/NeAntik-$VERSION-arm64-notarized.zip"

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  echo "Prepare the exact app first with scripts/prepare-direct-runtime-candidate.sh." >&2
  exit 64
fi
case "${NEANTIK_RELEASE_CHANNEL:-}" in
  public-alpha|production)
    ;;
  *)
    echo "Set NEANTIK_RELEASE_CHANNEL to public-alpha or production." >&2
    exit 64
    ;;
esac
: "${NEANTIK_NOTARY_PROFILE:?Set NEANTIK_NOTARY_PROFILE to an xcrun notarytool Keychain profile}"
: "${NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL:?Set NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL to the final public HTTPS download URL for $ARCHIVE_PATH}"

if [[ ! -d "$APP_PATH" || ! -f "$CANDIDATE_MANIFEST" ||
      -L "$CANDIDATE_MANIFEST" ]]; then
  echo "Prepared NeAntik.app and immutable candidate manifest are required." >&2
  exit 66
fi

python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL" \
  --fingerprint-evidence "$PROJECT_DIR/dist/fingerprint-audit.json"
"$PROJECT_DIR/scripts/verify-direct-version-bump.py"
"$PROJECT_DIR/scripts/notarize-direct-candidate.sh"
python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL" \
  --fingerprint-evidence "$PROJECT_DIR/dist/fingerprint-audit.json"
"$PROJECT_DIR/scripts/verify-direct-notarized-archive.py"

echo "$ARCHIVE_PATH"
echo "Next: upload the versioned archive, then run scripts/verify-direct-hosted-download.py with the candidate manifest and release channel."
