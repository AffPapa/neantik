#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"

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

python3 "$PROJECT_DIR/scripts/direct-candidate-manifest.py" verify \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL" \
  --fingerprint-evidence "$PROJECT_DIR/dist/fingerprint-audit.json"
"$PROJECT_DIR/scripts/verify-direct-version-bump.py"
"$PROJECT_DIR/scripts/notarize-direct-candidate.sh"

echo "Next: upload the versioned archive, then run scripts/verify-direct-hosted-download.py with --candidate-manifest, --release-channel, --fingerprint-evidence and --fingerprint-attestation."
