#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 foundation|fingerprint|profiles-a|profiles-b" >&2
  exit 64
fi

SHARD="$1"
case "$SHARD" in
  foundation)
    SUITES=(
      ApplicationEnvironmentTests
      AppPathsTests
      AccessibilityPresentationTests
      BrowserLaunchActionPresentationTests
      BrowserLaunchBuilderTests
      BrowserLaunchPreparationPolicyTests
      BrowserLaunchStagedPreflightTests
      BrowserLaunchPolicyTests
      BrowserProcessInventoryTests
      BrowserProcessLifecyclePresentationTests
      BrowserProcessManagerTests
      BrowserRuntimeInspectorTests
      BrowserRuntimePreflightTests
      BulkProxyActionProjectionTests
      BulkProxyImportTests
      BulkProxyRunProgressTests
      DisplayDateFormattingTests
      UserNoticeTests
    )
    ;;
  fingerprint)
    SUITES=(
      EnvironmentDiagnosticAssessmentTests
      FingerprintAuditLoopbackSTUNServerTests
      FingerprintAuditAutomationPolicyTests
      FingerprintAuditObservationTests
      FingerprintAuditTests
      FingerprintEvidenceEnrollmentTests
      FingerprintEvidenceEnvelopeTests
      FingerprintEvidenceReleaseContextTests
      FirstProfileBootstrapTests
      SecureEnclaveFingerprintEvidenceSignerTests
      KeychainStoreTests
      LaunchIntentTests
      ManagerSessionEvidenceTests
      ManagerStartupProbeTests
      NativeMenuLocalizationTests
      NeAntikShortcutCatalogTests
      NeAntikErrorPresentationTests
    )
    ;;
  profiles-a)
    SUITES=(
      ProfileCommandPresentationTests
      ProfileBatchActionsTests
      ProfileEditorProcessPolicyTests
      ProfileEditorPasswordTests
      ProfileEditorPresentationTests
      ProfileEditorValidationTests
      ProfileEnvironmentInspectorTests
      ProfileEnvironmentPresentationTests
      ProfileEnvironmentAccessibilityTests
      ProfileListProjectionTests
      ProfileOperationalProjectionTests
      ProfileListOrderingTests
      ProfileOrganizationTests
      ProfileOrganizationPersistenceTests
      ProfilePostSaveRevealPolicyTests
      ProfileRevisionAndTransactionTests
      ProfileTagAppearanceTests
    )
    ;;
  profiles-b)
    SUITES=(
      ProfileTagEditorTests
      ProfileStoreTests
      ProfileStorageMeasurementTests
      ProxyHealthTests
      ProxyImportParserTests
      ProxyTestOperationRegistryTests
      ProxyTesterTests
      ResponsiveLayoutRenderTests
      WorkspaceDomainTests
      WorkspaceLayoutTests
      WorkspacePreferenceStoreTests
      WorkspaceQueryStateTests
      WorkspaceReadinessTests
      RuntimePreferenceStoreTests
      TelemetryTests
      UpdateManifestTests
    )
    ;;
  *)
    echo "Unknown Swift test shard: $SHARD" >&2
    exit 64
    ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="$(
  "$PROJECT_DIR/scripts/resolve-compatible-developer-dir.sh"
)"
SWIFT_TEST_ROOT="$(mktemp -d /private/tmp/neantik-swift-shard-XXXXXX)"

cleanup() {
  if [[ -n "${SWIFT_TEST_ROOT:-}" && "$SWIFT_TEST_ROOT" == /private/tmp/neantik-swift-shard-* && -d "$SWIFT_TEST_ROOT" ]]; then
    rm -rf "$SWIFT_TEST_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p \
  "$SWIFT_TEST_ROOT/swiftpm-home" \
  "$SWIFT_TEST_ROOT/module-cache" \
  "$SWIFT_TEST_ROOT/build" \
  "$SWIFT_TEST_ROOT/results"

echo "Running NeAntik Swift shard: $SHARD via $DEVELOPER_DIR"
for SUITE in "${SUITES[@]}"; do
  TEST_OUTPUT="$SWIFT_TEST_ROOT/results/$SUITE.txt"
  echo "Running NeAntik Swift suite: $SUITE"
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
done

echo "NeAntik Swift shard verified: $SHARD (${#SUITES[@]} suites)"
