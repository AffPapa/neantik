import Foundation
import Testing
@testable import NeAntik

private final class BackupCompositionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var selected: [(String, String?)] = []
    let backend = MemoryBackupScopeBackend(Data(repeating: 9, count: 32))
    func make(_ service: String, _ group: String?) -> any BackupCompatibilityScopeBackend {
        lock.lock(); selected.append((service, group)); lock.unlock()
        return backend
    }
    var choices: [(String, String?)] { lock.lock(); defer { lock.unlock() }; return selected }
}

struct BackupApplicationCompositionTests {
    @Test func productionCapabilityUsesExplicitGroupAndDoesNotCreateAtStartup() throws {
        let recorder = BackupCompositionRecorder()
        let environment = NeAntikApplicationEnvironment.resolve(bundleIdentifier: NeAntikApplicationEnvironment.productionBundleIdentifier)
        let composition = try BackupApplicationComposition.resolve(environment: environment,
            paths: AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-production-capability-synthetic")),
            validatedReleaseAudit: false, bundleIdentifier: environment.bundleIdentifier,
            productionEnabled: true, securityBackend: { recorder.make($0, $1) })
        #expect(composition.allowsNewOperations)
        #expect(recorder.choices.count == 1)
        #expect(recorder.choices.first?.0 == "app.neantik.desktop.browser-data-backup-scope")
        #expect(recorder.choices.first?.1 == BackupApplicationComposition.productionAccessGroup)
        #expect(recorder.backend.insertionCount == 0)
    }

    @Test func productionCapabilityCannotSelectDevelopmentOrQAIdentity() {
        for bundle in [nil, NeAntikApplicationEnvironment.developmentBundleIdentifier,
                       BackupGUIQualificationContext.bundleIdentifier] as [String?] {
            let recorder = BackupCompositionRecorder()
            #expect(throws: BackupCompatibilityScopeError.unavailable) {
                try BackupApplicationComposition.resolve(environment: .resolve(bundleIdentifier: bundle),
                    paths: AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-foreign-capability-synthetic")),
                    validatedReleaseAudit: false, bundleIdentifier: bundle, productionEnabled: true,
                    securityBackend: { recorder.make($0, $1) })
            }
            #expect(recorder.choices.isEmpty)
        }
    }

    @Test func validatedAuditCannotAccessOrCreateScopeEvenWithProductionSettings() throws {
        let recorder = BackupCompositionRecorder()
        let environment = NeAntikApplicationEnvironment.resolve(bundleIdentifier: NeAntikApplicationEnvironment.productionBundleIdentifier)
        let composition = try BackupApplicationComposition.resolve(environment: environment,
            paths: AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-audit-composition-synthetic")),
            validatedReleaseAudit: true, bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier,
            developmentEnabled: true, productionEnabled: true, securityBackend: { recorder.make($0, $1) })
        #expect(!composition.allowsNewOperations)
        #expect(recorder.choices.isEmpty)
        for create in [false, true] {
            #expect(throws: BackupCompatibilityScopeError.unavailable) { try composition.scope.digest(createForExport: create) }
        }
        #expect(recorder.choices.isEmpty)
        #expect(recorder.backend.insertionCount == 0)
    }

    @Test func productionRetainsExistingScopeButNeverEnablesNewOperations() throws {
        let recorder = BackupCompositionRecorder()
        let environment = NeAntikApplicationEnvironment.resolve(bundleIdentifier: NeAntikApplicationEnvironment.productionBundleIdentifier)
        let composition = try BackupApplicationComposition.resolve(environment: environment,
            paths: AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-production-composition-synthetic")),
            validatedReleaseAudit: false, bundleIdentifier: environment.bundleIdentifier,
            developmentEnabled: true, securityBackend: { recorder.make($0, $1) })
        #expect(!composition.allowsNewOperations)
        #expect(recorder.choices.count == 1)
        #expect(recorder.choices.first?.0 == "app.neantik.desktop.browser-data-backup-scope")
        #expect(recorder.choices.first?.1 == nil)
        #expect(try composition.scope.digest(createForExport: false) ==
            BackupCompatibilityScopeStore(backend: recorder.backend).digest(createForExport: false))
    }

    @Test func misplacedQAMarkersNeverFallBackToAnOrdinaryLibrary() {
        #expect(throws: BackupCompatibilityScopeError.unavailable) {
            try BackupGUIQualificationContext.resolve(bundleIdentifier: NeAntikApplicationEnvironment.productionBundleIdentifier,
                runID: UUID().uuidString, root: "/private/tmp/neantik-untrusted-synthetic")
        }
        #expect(throws: BackupCompatibilityScopeError.unavailable) {
            try BackupApplicationComposition.resolve(environment: .resolve(bundleIdentifier: nil),
                paths: AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-untrusted-synthetic")),
                validatedReleaseAudit: false, bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier,
                securityBackend: { _, _ in Issue.record("Invalid QA selection reached Security factory"); return MemoryBackupScopeBackend() })
        }
    }

    #if DEBUG
    @Test func validQASelectsOnlyApprovedGroupAndRunScopedServiceAcrossReopen() throws {
        let run = UUID(), recorder = BackupCompositionRecorder()
        let root = BackupScopeQualification.dataRoot(run)
        let context = try #require(try BackupGUIQualificationContext.resolve(bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier,
            runID: run.uuidString, root: root.path))
        #expect(context.service == BackupScopeQualification.scopeService(run))
        for _ in 0..<2 {
            let composition = try BackupApplicationComposition.resolve(environment: .resolve(bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier),
                paths: AppPaths(rootDirectory: root), validatedReleaseAudit: false, qualification: context,
                bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier,
                fixtureRoot: root.path, developmentEnabled: false, securityBackend: { recorder.make($0, $1) })
            #expect(composition.allowsNewOperations)
            #expect(try composition.scope.digest(createForExport: false).count == 64)
        }
        #expect(recorder.choices.count == 2)
        #expect(recorder.choices.allSatisfy { $0.0 == context.service && $0.1 == BackupGUIQualificationContext.accessGroup })
        #expect(recorder.backend.insertionCount == 0)
    }

    @Test func QARootRunAndIdentityMismatchesRefuseBeforeBackendSelection() throws {
        let run = UUID(), root = BackupScopeQualification.dataRoot(run)
        for value in [nil, root.path + "/../other", BackupScopeQualification.dataRoot(UUID()).path, "/private/tmp/neantik-dev-fixture.fake"] as [String?] {
            #expect(throws: BackupCompatibilityScopeError.unavailable) {
                try BackupGUIQualificationContext.resolve(bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier,
                    runID: run.uuidString, root: value)
            }
        }
        let context = try #require(try BackupGUIQualificationContext.resolve(bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier,
            runID: run.uuidString, root: root.path))
        let recorder = BackupCompositionRecorder()
        #expect(throws: BackupCompatibilityScopeError.unavailable) {
            try BackupApplicationComposition.resolve(environment: .resolve(bundleIdentifier: NeAntikApplicationEnvironment.productionBundleIdentifier),
                paths: AppPaths(rootDirectory: root), validatedReleaseAudit: false, qualification: context,
                bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier, securityBackend: { recorder.make($0, $1) })
        }
        #expect(throws: BackupCompatibilityScopeError.unavailable) {
            try BackupApplicationComposition.resolve(environment: .resolve(bundleIdentifier: nil),
                paths: AppPaths(rootDirectory: BackupScopeQualification.dataRoot(UUID())), validatedReleaseAudit: false,
                qualification: context, bundleIdentifier: BackupGUIQualificationContext.bundleIdentifier,
                securityBackend: { recorder.make($0, $1) })
        }
        #expect(recorder.choices.isEmpty)
    }
    #endif
}
