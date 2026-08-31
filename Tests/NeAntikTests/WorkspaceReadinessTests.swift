import Foundation
import Testing
@testable import NeAntik

struct WorkspaceReadinessTests {
    @Test func readySnapshotKeepsAllChecksGreen() {
        let snapshot = WorkspaceReadinessSnapshot.resolve(
            input(
                storage: .ready(availableCapacity: 80_000_000_000),
                runtimeAvailability: .ready,
                profileCount: 2,
                runningCount: 1,
                proxiedRouteCount: 2
            )
        )

        #expect(snapshot.level == .ready)
        #expect(snapshot.title == "NeAntik готов")
        #expect(snapshot.items.count == 5)
        #expect(snapshot.items.allSatisfy { $0.level == .ready })
    }

    @Test func blockingRuntimeOutranksWarnings() {
        let snapshot = WorkspaceReadinessSnapshot.resolve(
            input(
                applicationLocation: .elsewhere,
                storage: .readOnly,
                runtimeAvailability: .missing,
                profileCount: 3,
                directRouteCount: 3
            )
        )

        #expect(snapshot.level == .blocked)
        #expect(snapshot.items.first { $0.id == .runtime }?.level == .blocked)
        #expect(snapshot.items.first { $0.id == .storage }?.level == .blocked)
        #expect(snapshot.items.first { $0.id == .routes }?.level == .attention)
    }

    @Test func checkingSnapshotWaitsForRuntimeAndStorage() {
        let snapshot = WorkspaceReadinessSnapshot.resolve(
            input(
                storage: .checking,
                runtimeAvailability: .resolving,
                profileCount: 0
            )
        )

        #expect(snapshot.level == .checking)
        #expect(snapshot.title == "Проверяем готовность…")
        #expect(snapshot.items.first { $0.id == .runtime }?.level == .checking)
        #expect(snapshot.items.first { $0.id == .storage }?.level == .checking)
    }

    @Test func directRoutesAndRecoveryRemainNonBlockingAttention() {
        let snapshot = WorkspaceReadinessSnapshot.resolve(
            input(
                storage: .ready(availableCapacity: nil),
                runtimeAvailability: .ready,
                profileCount: 4,
                runningCount: 1,
                processAttentionCount: 1,
                directRouteCount: 2,
                proxiedRouteCount: 2
            )
        )

        #expect(snapshot.level == .attention)
        #expect(snapshot.summary.contains("предупреждения"))
        #expect(snapshot.items.first { $0.id == .processes }?.level == .attention)
        #expect(snapshot.items.first { $0.id == .routes }?.level == .attention)
    }

    @Test func copiedDiagnosticExcludesPathsMessagesAndSecrets() {
        let snapshot = WorkspaceReadinessSnapshot.resolve(
            input(
                applicationLocation: .elsewhere,
                bundlePath: "/Users/alice/Downloads/NeAntik.app",
                storage: .unavailable,
                runtimeAvailability: .invalid(
                    message:
                        "password=hunter2 seed phrase /Users/alice/private"
                ),
                profileCount: 1,
                directRouteCount: 1
            )
        )

        let diagnostic = snapshot.diagnosticText.lowercased()
        #expect(!diagnostic.contains("/users/alice"))
        #expect(!diagnostic.contains("hunter2"))
        #expect(!diagnostic.contains("seed phrase"))
        #expect(!diagnostic.contains("password"))
        #expect(diagnostic.contains("runtime=invalid"))
        #expect(diagnostic.contains("location=elsewhere"))
    }

    @Test func systemInspectorReportsAccessibleTemporaryRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "neantik-readiness-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let inspection = WorkspaceReadinessSystemInspector.inspect(
            application: application(),
            dataRootURL: root
        )

        guard case .ready = inspection.storage else {
            Issue.record("Expected writable temporary root")
            return
        }
    }

    @Test func accessibilitySummaryIncludesTextualState() {
        let item = WorkspaceReadinessItem(
            id: .runtime,
            title: "Браузерный движок",
            value: "Не найден",
            detail: "Переустанови приложение.",
            level: .blocked
        )

        #expect(item.accessibilitySummary.contains("Исправь"))
        #expect(item.accessibilitySummary.contains("Не найден"))
        #expect(item.accessibilitySummary.contains("Переустанови"))
    }

    private func input(
        applicationLocation: WorkspaceApplicationLocation = .development,
        bundlePath: String =
            "/private/tmp/NeAntik-Dev.app",
        storage: WorkspaceStorageState,
        runtimeAvailability: BrowserRuntimeAvailability,
        profileCount: Int,
        runningCount: Int = 0,
        processAttentionCount: Int = 0,
        directRouteCount: Int = 0,
        proxiedRouteCount: Int = 0,
        proxyAttentionCount: Int = 0
    ) -> WorkspaceReadinessInput {
        WorkspaceReadinessInput(
            system: WorkspaceReadinessSystemInspection(
                application: application(
                    location: applicationLocation,
                    bundlePath: bundlePath
                ),
                storage: storage
            ),
            runtimeAvailability: runtimeAvailability,
            runtimeVersion: "152.0.7977.64",
            runtimeArchitectures: ["arm64"],
            profileCount: profileCount,
            runningCount: runningCount,
            processAttentionCount: processAttentionCount,
            directRouteCount: directRouteCount,
            proxiedRouteCount: proxiedRouteCount,
            proxyAttentionCount: proxyAttentionCount
        )
    }

    private func application(
        location: WorkspaceApplicationLocation = .development,
        bundlePath: String = "/private/tmp/NeAntik-Dev.app"
    ) -> WorkspaceApplicationIdentity {
        WorkspaceApplicationIdentity(
            displayName: "NeAntik Dev",
            version: "0.3.22",
            build: "25",
            bundleIdentifier:
                NeAntikApplicationEnvironment.developmentBundleIdentifier,
            bundlePath: bundlePath,
            location: location
        )
    }
}
