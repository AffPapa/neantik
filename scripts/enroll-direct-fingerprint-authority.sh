#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /absolute/path/to/NeAntik.app /absolute/path/to/fingerprint-enrollment.json" >&2
  exit 64
fi

APP_PATH="$1"
OUTPUT_PATH="$2"
EXECUTABLE="$APP_PATH/Contents/MacOS/NeAntik"
LOG_PATH="${OUTPUT_PATH}.log"

if [[ "$APP_PATH" != /* || ! -d "$APP_PATH" || -L "$APP_PATH" ]]; then
  echo "Fingerprint enrollment requires one absolute regular app bundle." >&2
  exit 66
fi
if [[ "$OUTPUT_PATH" != /* || -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
  echo "Fingerprint enrollment output must be one new absolute file." >&2
  exit 65
fi
if [[ ! -x "$EXECUTABLE" || -L "$EXECUTABLE" ]]; then
  echo "Fingerprint enrollment requires the exact regular app executable." >&2
  exit 66
fi
if [[ "${NEANTIK_LOCAL_ADHOC:-0}" == "1" ]]; then
  echo "Ad-hoc builds cannot enroll a public Direct release authority." >&2
  exit 65
fi
if [[ "$(/usr/bin/stat -f '%u' /dev/console)" != "$EUID" ]]; then
  echo "Run fingerprint enrollment from the signed-in user's Terminal session." >&2
  exit 69
fi
if ! /bin/launchctl print "gui/$EUID" >/dev/null 2>&1; then
  echo "The signed-in macOS user session is unavailable." >&2
  exit 69
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
python3 "$PROJECT_DIR/scripts/verify-direct-provisioning-profile.py" \
  --profile "$APP_PATH/Contents/embedded.provisionprofile" \
  --app "$APP_PATH"
SIGNATURE_DETAILS="$(/usr/bin/codesign -dvvv "$APP_PATH" 2>&1)"
if ! /usr/bin/grep -Fq "Authority=Developer ID Application:" \
    <<<"$SIGNATURE_DETAILS"; then
  echo "Fingerprint enrollment requires a Developer ID Application signature." >&2
  exit 65
fi
if ! /usr/bin/grep -Fq "Timestamp=" <<<"$SIGNATURE_DETAILS"; then
  echo "Fingerprint enrollment requires a trusted signing timestamp." >&2
  exit 65
fi

if [[ -e "$LOG_PATH" || -L "$LOG_PATH" ]]; then
  echo "Fingerprint enrollment log already exists; refusing overwrite." >&2
  exit 65
fi

enrollment_status=0
/usr/bin/env \
  -u DYLD_INSERT_LIBRARIES \
  -u DYLD_LIBRARY_PATH \
  -u DYLD_FRAMEWORK_PATH \
  -u DYLD_FALLBACK_LIBRARY_PATH \
  /usr/bin/python3 "$PROJECT_DIR/scripts/run-exact-command-with-timeout.py" \
    --timeout 60 \
    --log "$LOG_PATH" \
    -- \
    "$EXECUTABLE" \
    --neantik-enroll-fingerprint-evidence \
    --output "$OUTPUT_PATH" || enrollment_status=$?

if (( enrollment_status != 0 )); then
  echo "Secure Enclave enrollment failed; Direct release preparation stopped." >&2
  exit "$enrollment_status"
fi
if [[ ! -f "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
  echo "Secure Enclave enrollment did not create a safe public binding." >&2
  exit 65
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
