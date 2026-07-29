#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_BUILD_ROOT="$(mktemp -d /private/tmp/neantik-swift-release-XXXXXX)"

cleanup() {
  if [[ -n "${SWIFT_BUILD_ROOT:-}" && "$SWIFT_BUILD_ROOT" == /private/tmp/neantik-swift-release-* && -d "$SWIFT_BUILD_ROOT" ]]; then
    rm -rf "$SWIFT_BUILD_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p \
  "$SWIFT_BUILD_ROOT/swiftpm-home" \
  "$SWIFT_BUILD_ROOT/module-cache" \
  "$SWIFT_BUILD_ROOT/build"

echo "Building NeAntik release with isolated writable caches..."

(
  cd "$PROJECT_DIR"
  SWIFTPM_HOME="$SWIFT_BUILD_ROOT/swiftpm-home" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_BUILD_ROOT/module-cache" \
    swift build \
      -c release \
      --disable-sandbox \
      --scratch-path "$SWIFT_BUILD_ROOT/build"
)

echo "NeAntik native release build verified."
