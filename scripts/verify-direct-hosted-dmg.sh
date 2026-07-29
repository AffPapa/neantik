#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PROJECT_DIR/Resources/Info.plist"
)"
EXPECTED_NAME="NeAntik-$EXPECTED_VERSION-arm64-notarized.dmg"
LOCAL_DMG="$PROJECT_DIR/dist/$EXPECTED_NAME"
DOWNLOAD_URL="${1:-${NEANTIK_DMG_DOWNLOAD_URL:-}}"

fail() {
  echo "Direct hosted DMG verification failed: $*" >&2
  exit 65
}

[[ -n "$DOWNLOAD_URL" ]] ||
  fail "pass the final public HTTPS DMG URL as the first argument"
[[ "$DOWNLOAD_URL" == https://* ]] ||
  fail "download URL must use HTTPS"
[[ "$DOWNLOAD_URL" != *"@"* ]] ||
  fail "download URL must not contain credentials"
[[ "$DOWNLOAD_URL" != *"#"* ]] ||
  fail "download URL must not contain a fragment"
[[ "${DOWNLOAD_URL%%\?*}" == */"$EXPECTED_NAME" ]] ||
  fail "download URL basename must be $EXPECTED_NAME"

"$PROJECT_DIR/scripts/verify-direct-notarized-dmg.sh" "$LOCAL_DMG"

EXPECTED_SHA="$(shasum -a 256 "$LOCAL_DMG" | awk '{print $1}')"
EXPECTED_SIZE="$(stat -f '%z' "$LOCAL_DMG")"
TEMP_ROOT="$(mktemp -d -t neantik-hosted-dmg)"
DOWNLOADED_DMG="$TEMP_ROOT/$EXPECTED_NAME"
trap 'rm -rf "$TEMP_ROOT"' EXIT

curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --max-time 900 \
  --user-agent 'NeAntik-release-verifier/1.0' \
  --output "$DOWNLOADED_DMG" \
  "$DOWNLOAD_URL"

DOWNLOADED_SHA="$(shasum -a 256 "$DOWNLOADED_DMG" | awk '{print $1}')"
DOWNLOADED_SIZE="$(stat -f '%z' "$DOWNLOADED_DMG")"
[[ "$DOWNLOADED_SHA" == "$EXPECTED_SHA" ]] ||
  fail "downloaded SHA-256 differs: remote=$DOWNLOADED_SHA local=$EXPECTED_SHA"
[[ "$DOWNLOADED_SIZE" == "$EXPECTED_SIZE" ]] ||
  fail "downloaded size differs: remote=$DOWNLOADED_SIZE local=$EXPECTED_SIZE"

print -r -- "$DOWNLOADED_SHA  $EXPECTED_NAME" >"$DOWNLOADED_DMG.sha256"
"$PROJECT_DIR/scripts/verify-direct-notarized-dmg.sh" "$DOWNLOADED_DMG"

echo
echo "PASS: Direct hosted DMG contract verified."
echo "Download URL: $DOWNLOAD_URL"
echo "Size: $DOWNLOADED_SIZE bytes"
echo "SHA-256: $DOWNLOADED_SHA"
