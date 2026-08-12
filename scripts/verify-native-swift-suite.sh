#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 SwiftSuiteName" >&2
  exit 64
fi

SUITE="$1"
case "$SUITE" in
  ApplicationEnvironmentTests|\
  AppPathsTests|\
  BrowserLaunchBuilderTests|\
  BrowserProcessInventoryTests|\
  BrowserProcessManagerTests|\
  BrowserRuntimeInspectorTests|\
  BrowserRuntimePreflightTests|\
  BulkProxyImportTests|\
  FingerprintAuditAutomationPolicyTests|\
  FingerprintAuditLoopbackSTUNServerTests|\
  FingerprintAuditTests|\
  FingerprintEvidenceEnrollmentTests|\
  FingerprintEvidenceEnvelopeTests|\
  FingerprintEvidenceReleaseContextTests|\
  SecureEnclaveFingerprintEvidenceSignerTests|\
  KeychainStoreTests|\
  LaunchIntentTests|\
  ProfileEditorPasswordTests|\
  ProfileOrganizationTests|\
  ProfileStoreTests|\
  ProxyImportParserTests|\
  ProxyTesterTests|\
  ResponsiveLayoutRenderTests|\
  WorkspaceLayoutTests|\
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
TEST_OUTPUT="$SWIFT_TEST_ROOT/test-output.txt"

(
  cd "$PROJECT_DIR"
  SWIFTPM_HOME="$SWIFT_TEST_ROOT/swiftpm-home" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_TEST_ROOT/module-cache" \
    swift test \
      --disable-sandbox \
      --scratch-path "$SWIFT_TEST_ROOT/build" \
      --filter "$SUITE"
) 2>&1 | tee "$TEST_OUTPUT"

if ! grep -Eq \
  'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' \
  "$TEST_OUTPUT"; then
  echo "Swift suite did not execute a positive test count: $SUITE" >&2
  exit 1
fi

echo "NeAntik Swift suite verified: $SUITE"
