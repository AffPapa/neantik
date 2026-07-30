#!/bin/zsh

set -euo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
REPORT_PATH="$PROJECT_DIR/dist/fingerprint-audit.json"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
SUMMARY_PATH="$PROJECT_DIR/dist/fingerprint-audit-summary.json"

: "${NEANTIK_NOTARY_PROFILE:?Set NEANTIK_NOTARY_PROFILE to a notarytool Keychain profile}"
case "${NEANTIK_RELEASE_CHANNEL:-}" in
  public-alpha | production)
    ;;
  *)
    echo "Set NEANTIK_RELEASE_CHANNEL to public-alpha or production." >&2
    exit 64
    ;;
esac

exec python3 "$PROJECT_DIR/scripts/notarize_direct_transaction.py" \
  --project-root "$PROJECT_DIR" \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --evidence "$REPORT_PATH" \
  --attestation "$SUMMARY_PATH" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL"
