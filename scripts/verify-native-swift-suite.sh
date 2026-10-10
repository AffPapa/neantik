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
  AccessibilityPresentationTests|\
  BrowserLaunchActionPresentationTests|\
  BrowserLaunchBuilderTests|\
  BrowserLaunchPreparationPolicyTests|\
  BrowserLaunchPolicyTests|\
  BrowserProcessInventoryTests|\
  BrowserProcessManagerTests|\
  BrowserSessionObservationTests|\
  BrowserRuntimeInspectorTests|\
  BrowserRuntimePreflightTests|\
  BulkProxyActionProjectionTests|\
  BulkProxyImportTests|\
  CRX3SignatureVerifierTests|\
  DisplayDateFormattingTests|\
  EnvironmentDiagnosticAssessmentTests|\
  FingerprintAuditReadinessPolicyTests|\
  FingerprintAuditAutomationPolicyTests|\
  FingerprintAuditLoopbackSTUNServerTests|\
  FingerprintAuditObservationTests|\
  FingerprintAuditTriggerPolicyTests|\
  FingerprintAuditTests|\
  FingerprintEvidenceEnrollmentTests|\
  FingerprintEvidenceEnvelopeTests|\
  FingerprintEvidenceReleaseContextTests|\
  FirstProfileBootstrapTests|\
  ProfileArtifactProvenanceTests|\
  ProfileDiagnosticsSummaryTests|\
  RedactedSupportBundleTests|\
  SecureEnclaveFingerprintEvidenceSignerTests|\
  KeychainStoreTests|\
  LaunchIntentTests|\
  NativeMenuLocalizationTests|\
  ProfileCommandPresentationTests|\
  ProfileConfigurationTransferFileImportTests|\
  ProfileConfigurationTransferTests|\
  ProfileEditorPasswordTests|\
  ProfileEditorPresentationTests|\
  ProfileSnapshotSaveSummaryTests|\
  ProfileEditorValidationTests|\
  ProfileEnvironmentInspectorTests|\
  ProfileEnvironmentPresentationTests|\
  ProfileEnvironmentAccessibilityTests|\
  ProfileLifecycleHealthTests|\
  ProfileListProjectionTests|\
  ProfileManagerPerformanceBudgetTests|\
  ProfileOrganizationTests|\
  ProfileOrganizationPersistenceTests|\
  ProfilePostSaveRevealPolicyTests|\
  ProfilePrivacyPanelTests|\
  ProxyCheckSummaryTests|\
  ProfileSnapshotTests|\
  SiteCompatibilityAssessmentTests|\
  ProfileRevisionAndTransactionTests|\
  ProfileTagAppearanceTests|\
  ProfileTagEditorTests|\
  ManagedBrowserQuitTests|\
  ManagerLaunchAdmissionTests|\
  ManagerLibraryTests|\
  ManagerSearchBenchmarkTests|\
  ProfileMetadataUndoTests|\
  ProfileStoreTests|\
  PrivateGuardLeaseTests|\
  ProxyHealthTests|\
  ProxyImportParserTests|\
  ProxyTestOperationRegistryTests|\
  ProxyTesterTests|\
  ResponsiveLayoutRenderTests|\
  RuntimeProvenanceCardTests|\
  WorkspaceDomainTests|\
  WorkspaceLayoutTests|\
  WorkspaceQueryStateTests|\
  RuntimePreferenceStoreTests|\
  TelemetryTests|\
  DevelopmentWorkspaceFixtureTests|\
  HelpContentTests|\
  MCPInteroperabilityTests|\
  MCPProfileManagementTests|\
  MCPStdioServerTests|\
  MCPWorkspaceQueryTests|\
  ProfileQuickCommandProjectionTests|\
  ProxyTesterLiveFixtureTests|\
  DirectUpdateArchiveIntegrityTests|\
  BackupCompatibilityScopeStoreTests|\
  BookmarkImportTests|\
  BrowserDataBackupStorageTests|\
  BrowserDataRestoreTransactionTests|\
  DevelopmentFixtureBackupScopeTests|\
  DevelopmentFixtureKeychainTests|\
  EncryptedBackupArchiveTests|\
  EncryptedBackupFramingTests|\
  OwnedProfileDirectoryTests|\
  ProfileBrowserDataBackupServiceTests|\
  ProfileCacheMaintenanceTests|\
  ProxyDiagnosticTests|\
  ProxyRelayBrowserRoleDecoderTests|\
  ProxyRelayClientWireCodecTests|\
  ProxyRelayControlPeerInspectorTests|\
  ProxyRelayLiveCodeVerifierTests|\
  ProxyRelayLoopbackServerTests|\
  ProxyRelaySocketOwnerInspectorTests|\
  ProxyRelayWireCodecTests|\
  StoppedProfileRestoreAuthorityTests|\
  UpdateManifestTests)
    ;;
  *)
    echo "Unknown Swift test suite: $SUITE" >&2
    exit 64
    ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if ! RESOLVED_DEVELOPER_DIR="$(
  "$PROJECT_DIR/scripts/resolve-compatible-developer-dir.sh"
)"; then
  echo "No compatible Xcode developer directory; refusing to run Swift tests with an implicit toolchain." >&2
  exit 69
fi
if [[ -z "$RESOLVED_DEVELOPER_DIR" ]]; then
  echo "Xcode resolver returned an empty developer directory; refusing an implicit toolchain." >&2
  exit 69
fi
export DEVELOPER_DIR="$RESOLVED_DEVELOPER_DIR"
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

echo "Running NeAntik Swift suite: $SUITE via $DEVELOPER_DIR"
TEST_OUTPUT="$SWIFT_TEST_ROOT/test-output.txt"

(
  cd "$PROJECT_DIR"
  SWIFTPM_HOME="$SWIFT_TEST_ROOT/swiftpm-home" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_TEST_ROOT/module-cache" \
    swift test \
      --build-system native \
      --jobs 2 \
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
