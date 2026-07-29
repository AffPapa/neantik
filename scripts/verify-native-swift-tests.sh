#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_TEST_ROOT="$(mktemp -d /private/tmp/nevision-swift-cache-XXXXXX)"

cleanup() {
  if [[ -n "${SWIFT_TEST_ROOT:-}" && "$SWIFT_TEST_ROOT" == /private/tmp/nevision-swift-cache-* && -d "$SWIFT_TEST_ROOT" ]]; then
    rm -rf "$SWIFT_TEST_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p \
  "$SWIFT_TEST_ROOT/swiftpm-home" \
  "$SWIFT_TEST_ROOT/module-cache" \
  "$SWIFT_TEST_ROOT/build"

echo "Running NeAntik native Swift tests with isolated writable caches..."

(
  cd "$PROJECT_DIR"
  SWIFTPM_HOME="$SWIFT_TEST_ROOT/swiftpm-home" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_TEST_ROOT/module-cache" \
    swift test \
      --disable-sandbox \
      --scratch-path "$SWIFT_TEST_ROOT/build"
)

echo "NeAntik native Swift tests verified."
