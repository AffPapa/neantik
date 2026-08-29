#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REBASE_PLAN="$SCRIPT_DIR/../runtime/chromium-152-rebase-plan.json"

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

read_plan() {
  plutil -extract "$1" raw -o - "$REBASE_PLAN"
}

MAC_REPOSITORY="$(read_plan macPackaging.repository)"
MAC_COMMIT="$(read_plan macPackaging.commit)"
MAC_TREE="$(read_plan macPackaging.tree)"
COMMON_REPOSITORY="$(read_plan commonChromium.repository)"
COMMON_TAG="$(read_plan commonChromium.tag)"
COMMON_TAG_OBJECT="$(read_plan commonChromium.tagObject)"
COMMON_COMMIT="$(read_plan commonChromium.commit)"
COMMON_TREE="$(read_plan commonChromium.tree)"

if [[ ! -d "$DESTINATION" ]]; then
  mkdir -p "$(dirname "$DESTINATION")"
fi

git clone \
  --filter=blob:none \
  "$MAC_REPOSITORY" \
  "$DESTINATION"
git -C "$DESTINATION" checkout --detach "$MAC_COMMIT"

if [[ "$(git -C "$DESTINATION" rev-parse HEAD)" != "$MAC_COMMIT" ||
      "$(git -C "$DESTINATION" rev-parse HEAD^{tree})" != "$MAC_TREE" ]]; then
  echo "Pinned macOS packaging commit or tree does not match the rebase plan." >&2
  exit 65
fi

git clone \
  --filter=blob:none \
  --branch "$COMMON_TAG" \
  --single-branch \
  "$COMMON_REPOSITORY" \
  "$DESTINATION/ungoogled-chromium"

if [[ "$(git -C "$DESTINATION/ungoogled-chromium" rev-parse HEAD)" != "$COMMON_COMMIT" ||
      "$(git -C "$DESTINATION/ungoogled-chromium" rev-parse HEAD^{tree})" != "$COMMON_TREE" ||
      "$(git -C "$DESTINATION/ungoogled-chromium" rev-parse "refs/tags/$COMMON_TAG")" != "$COMMON_TAG_OBJECT" ]]; then
  echo "Pinned common Chromium tag, commit, or tree does not match the rebase plan." >&2
  exit 65
fi

python3 "$SCRIPT_DIR/verify-runtime-source-pair.py" "$DESTINATION"

echo
echo "Pinned source pair prepared at:"
echo "  $DESTINATION"
echo
echo "No Chromium archive was downloaded and no browser binary was built."
