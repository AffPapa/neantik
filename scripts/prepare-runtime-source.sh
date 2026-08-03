#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="$SCRIPT_DIR/../runtime/fingerprint-chromium.lock.json"
SOURCE_CONTRACT="$SCRIPT_DIR/../runtime/chromium-150-source-contract.json"

LOCKED_RUNTIME_VERSION="$(
  plutil -extract fingerprintChromium.chromiumVersion raw -o - "$LOCK_FILE"
)"
if [[ "$LOCKED_RUNTIME_VERSION" == 150.* && -f "$SOURCE_CONTRACT" ]]; then
  echo "Legacy source-pair preparation is blocked for Chromium 150." >&2
  echo "Use the pinned runtime/chromium-150-rebase-plan.json bootstrap and build-runtime.sh; the legacy lock still describes Chromium 144 packaging metadata." >&2
  exit 65
fi

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "Usage: $0 /absolute/path/to/nevision-chromium-build" >&2
  exit 64
fi

DESTINATION="$1"
if [[ "$DESTINATION" != /* ]]; then
  echo "Destination must be an absolute path." >&2
  exit 64
fi

if [[ -e "$DESTINATION" && ! -d "$DESTINATION" ]]; then
  echo "Destination exists and is not a directory: $DESTINATION" >&2
  exit 73
fi

if [[ -d "$DESTINATION" && -n "$(find "$DESTINATION" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Destination must be absent or empty: $DESTINATION" >&2
  exit 73
fi

read_lock() {
  plutil -extract "$1" raw -o - "$LOCK_FILE"
}

MAC_REPOSITORY="$(read_lock macPackaging.repository)"
MAC_TAG="$(read_lock macPackaging.tag)"
MAC_COMMIT="$(read_lock macPackaging.commit)"
FINGERPRINT_REPOSITORY="$(read_lock fingerprintChromium.repository)"
FINGERPRINT_TAG="$(read_lock fingerprintChromium.tag)"
FINGERPRINT_COMMIT="$(read_lock fingerprintChromium.commit)"

if [[ ! -d "$DESTINATION" ]]; then
  mkdir -p "$(dirname "$DESTINATION")"
fi

git clone \
  --filter=blob:none \
  --branch "$MAC_TAG" \
  --single-branch \
  "$MAC_REPOSITORY" \
  "$DESTINATION"

if [[ "$(git -C "$DESTINATION" rev-parse HEAD)" != "$MAC_COMMIT" ]]; then
  echo "Pinned macOS tag no longer resolves to the expected commit." >&2
  exit 65
fi

git clone \
  --filter=blob:none \
  --branch "$FINGERPRINT_TAG" \
  --single-branch \
  "$FINGERPRINT_REPOSITORY" \
  "$DESTINATION/ungoogled-chromium"

if [[ "$(git -C "$DESTINATION/ungoogled-chromium" rev-parse HEAD)" != "$FINGERPRINT_COMMIT" ]]; then
  echo "Pinned fingerprint tag no longer resolves to the expected commit." >&2
  exit 65
fi

"$SCRIPT_DIR/verify-runtime-source.sh" "$DESTINATION"

echo
echo "Pinned source pair prepared at:"
echo "  $DESTINATION"
echo
echo "No Chromium source was downloaded and no browser binary was built."
