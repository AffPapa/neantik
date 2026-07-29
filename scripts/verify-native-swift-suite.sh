#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 SwiftSuiteName" >&2
  exit 64
fi

SUITE="$1"
case "$SUITE" in
  AppPathsTests|\
  BrowserLaunchBuilderTests|\
  BrowserProcessManagerTests|\
  BrowserRuntimeInspectorTests|\
  BrowserRuntimePreflightTests|\
  FingerprintAuditLoopbackSTUNServerTests|\
  FingerprintAuditTests|\
  KeychainStoreTests|\
  LaunchIntentTests|\
  ProfileStoreTests|\
  ProxyTesterTests|\
  RuntimePreferenceStoreTests|\
  TelemetryTests|\
  UpdateManifestTests)
    ;;
  *)
    echo "Unknown Swift test suite: $SUITE" >&2
    exit 64
    ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_TEST_ROOT="$(mktemp -d /private/tmp/neantik-swift-suite-XXXXXX)"

cleanup() {
  if [[ -n "${SWIFT_TEST_ROOT:-}" && "$SWIFT_TEST_ROOT" == /private/tmp/neantik-swift-suite-* && -d "$SWIFT_TEST_ROOT" ]]; then
    rm -rf "$SWIFT_TEST_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p \
  "$SWIFT_TEST_ROOT/swiftpm-home" \
  "$SWIFT_TEST_ROOT/module-cache" \
  "$SWIFT_TEST_ROOT/build"

echo "Running NeAntik Swift suite: $SUITE"

(
  cd "$PROJECT_DIR"
  SWIFTPM_HOME="$SWIFT_TEST_ROOT/swiftpm-home" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_TEST_ROOT/module-cache" \
    swift test \
      --disable-sandbox \
      --scratch-path "$SWIFT_TEST_ROOT/build" \
      --filter "$SUITE"
)

echo "NeAntik Swift suite verified: $SUITE"
