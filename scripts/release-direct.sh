#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
VERSION="$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleShortVersionString' \
  "$PROJECT_DIR/Resources/Info.plist")"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Resources/Info.plist contains an invalid release version." >&2
  exit 65
fi
EXPECTED_ARCHIVE="NeAntik-$VERSION-arm64-notarized.zip"

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
: "${NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL:?Set NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL to the final versioned public HTTPS ZIP URL}"

if [[ ! -d "$APP_PATH" || ! -f "$CANDIDATE_MANIFEST" ||
      -L "$CANDIDATE_MANIFEST" ]]; then
  echo "Prepared NeAntik.app and immutable candidate manifest are required." >&2
  exit 66
fi

RELEASE_PYTHON="/opt/homebrew/bin/python3"
if [[ ! -x "$RELEASE_PYTHON" ]] ||
   ! "$RELEASE_PYTHON" -I -B -c \
     'import platform,sys; raise SystemExit(0 if sys.version_info >= (3,11) and platform.machine() == "arm64" else 1)'
then
  echo "ARM64 Python 3.11+ is required at /opt/homebrew/bin/python3." >&2
  exit 69
fi

"$RELEASE_PYTHON" -I -B \
  "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
  "$PROJECT_DIR/scripts/verify-browser-identity-issuance.py"
"$RELEASE_PYTHON" -I -B \
  "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
  "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL" \
  --fingerprint-evidence "$PROJECT_DIR/dist/fingerprint-audit.json"
"$RELEASE_PYTHON" -I -B \
  "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
  "$PROJECT_DIR/scripts/verify-direct-version-bump.py"
"$RELEASE_PYTHON" -I -B \
  "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
  "$PROJECT_DIR/scripts/notary_transaction_inspector.py" \
  --project-root "$PROJECT_DIR" \
  --expected-archive-name "$EXPECTED_ARCHIVE" \
  --release-gate
"$PROJECT_DIR/scripts/notarize-direct-candidate.sh"

echo "Next: upload the versioned archive, then run scripts/verify-direct-hosted-download.py with --candidate-manifest, --release-channel, --fingerprint-evidence and --fingerprint-attestation."
