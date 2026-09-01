#!/bin/zsh

set -euo pipefail
umask 077
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/NeAntik.app"
REPORT_PATH="$PROJECT_DIR/dist/fingerprint-audit.json"
CANDIDATE_MANIFEST="$PROJECT_DIR/dist/direct-candidate-manifest.json"
CANDIDATE_SOURCE_BINDING="$PROJECT_DIR/dist/direct-candidate-source.json"
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

# The source receipt rejects executable bytecode beside any tracked Python
# source. Tests may create these caches outside scripts/, so derive the exact
# cleanup scope from Git instead of maintaining a fragile hard-coded list.
git -C "$PROJECT_DIR" ls-files -z -- '*.py' |
  while IFS= read -r -d '' tracked_python; do
    python_parent="$PROJECT_DIR/$(dirname "$tracked_python")"
    python_cache="$python_parent/__pycache__"
    if [[ -d "$python_cache" ]]; then
      find "$python_cache" -depth -delete
    fi
    find "$python_parent" -maxdepth 1 -type f -name '*.pyc' -delete
  done

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

exec "$RELEASE_PYTHON" -I -B \
  "$PROJECT_DIR/scripts/run-isolated-release-python.py" \
  "$PROJECT_DIR/scripts/notarize_direct_transaction.py" \
  --project-root "$PROJECT_DIR" \
  --app "$APP_PATH" \
  --manifest "$CANDIDATE_MANIFEST" \
  --source-binding "$CANDIDATE_SOURCE_BINDING" \
  --evidence "$REPORT_PATH" \
  --attestation "$SUMMARY_PATH" \
  --release-channel "$NEANTIK_RELEASE_CHANNEL"
