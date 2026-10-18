import CryptoKit
import Foundation
import Testing
@testable import NeAntik

@MainActor struct ProfileBrowserDataBackupServiceTests {
    private let fs = FileManager.default
    private let password = "own service fixture passphrase"
    private nonisolated static var runtime: BrowserRuntimeInspection {
        .init(version: "156.0.8078.12", architectures: ["arm64"], codeSignatureValid: true,
              executableSHA256: String(repeating: "a", count: 64), frameworkSHA256: String(repeating: "b", count: 64))
    }
    private func fixture(engine: BrowserEngine = .chromium) throws -> (AppPaths, ProfileStore, BrowserProfile, ProfileBrowserDataBackupService, MemoryBackupScopeBackend) {
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-backup-service-" + UUID().uuidString))
        let store = ProfileStore(paths: paths)
        var profile = BrowserProfile(name: "Own service fixture", engine: engine)
        profile.identity = BrowserIdentity(seed: 12345, timezoneIdentifier: "America/New_York", localeIdentifier: "en-US",
            proxyContextEvidence: .ipAPI(observedAt: Date(timeIntervalSince1970: 1_790_000_000.375)))
        profile = try store.upsert(profile)
        try paths.writePrivateFile(Data("original owned data".utf8), to: paths.browserDataDirectory(for: profile.id).appendingPathComponent("own-value"))
        let backend = MemoryBackupScopeBackend()
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
            processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let service = ProfileBrowserDataBackupService(paths: paths, processes: manager,
            scope: BackupCompatibilityScopeStore(backend: backend, random: { Data(repeating: 9, count: 32) }), inspectRuntime: { Self.runtime })
        return (paths, store, profile, service, backend)
    }
    @Test func serviceExportRestorePreservesDiskCanonicalIdentityAndOtherProfiles() async throws {
        let (paths, store, profile, service, _) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let other = try store.upsert(BrowserProfile(name: "Other metadata preserved"))
        let persistedOther = try ProfileStore.decodeProfiles(Data(contentsOf: paths.profilesFile)).first { $0.id == other.id }
        let file = paths.browserDataDirectory(for: profile.id).appendingPathComponent("own-value")
        let archive = paths.rootDirectory.appendingPathComponent("own.nabackup")
        let manifest = try await service.export(profileID: profile.id, expectedRevision: profile.revision, destination: archive, password: password)
        let disk = try ProfileStore.decodeProfiles(Data(contentsOf: paths.profilesFile)).first { $0.id == profile.id }!
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(disk.identity)).map { String(format: "%02x", $0) }.joined()
        #expect(manifest.identitySHA256 == digest)
        // Fractional UI timestamp is rounded on disk; hashing that UI identity
        // would reject the archive incorrectly after an application restart.
        let uiDigest = SHA256.hash(data: try encoder.encode(profile.identity)).map { String(format: "%02x", $0) }.joined()
        #expect(uiDigest != digest)
        try paths.writePrivateFile(Data("newer owned data".utf8), to: file)
        let result = try await service.restore(profileID: profile.id, expectedRevision: profile.revision, archive: archive, password: password)
        #expect(result.restored)
        #expect(try Data(contentsOf: file) == Data("original owned data".utf8))
        try await store.refreshExternalMetadata(force: true)
        #expect(store.profile(withID: profile.id)?.revision == profile.revision + 1)
        #expect(store.profile(withID: profile.id)?.identity == disk.identity)
        #expect(store.profile(withID: other.id) == persistedOther)
    }
    @Test(arguments: ["missing-scope", "changed-scope", "wrong-password", "stale-revision"])
    func restoreRefusesBadContextWithoutChangingLiveData(kind: String) async throws {
        let (paths, _, profile, service, backend) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let archive = paths.rootDirectory.appendingPathComponent("own.nabackup")
        _ = try await service.export(profileID: profile.id, expectedRevision: profile.revision, destination: archive, password: password)
        if kind == "missing-scope" { backend.replace(nil) }
        if kind == "changed-scope" { backend.replace(Data(repeating: 8, count: 32)) }
        let main = try Data(contentsOf: paths.profilesFile)
        do {
            _ = try await service.restore(profileID: profile.id, expectedRevision: profile.revision + (kind == "stale-revision" ? 1 : 0), archive: archive,
                password: kind == "wrong-password" ? "incorrect own passphrase" : password)
            Issue.record("Invalid restore context was accepted")
        } catch {}
        #expect(try Data(contentsOf: paths.profilesFile) == main)
        #expect(try Data(contentsOf: paths.browserDataDirectory(for: profile.id).appendingPathComponent("own-value")) == Data("original owned data".utf8))
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
        #expect(try fs.contentsOfDirectory(atPath: paths.profileDirectory(for: profile.id).path).filter { $0.hasPrefix(".neantik-backup-restore-") }.isEmpty)
    }
    @Test func changedRuntimeDuringRestoreRefusesBeforeActivationAndCleansOwnedStage() async throws {
        let (paths, _, profile, service, backend) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let archive = paths.rootDirectory.appendingPathComponent("own.nabackup")
        _ = try await service.export(profileID: profile.id, expectedRevision: profile.revision, destination: archive, password: password)
        let changed = BrowserRuntimeInspection(version: "156.0.8078.12", architectures: ["arm64"], codeSignatureValid: true,
            executableSHA256: String(repeating: "c", count: 64), frameworkSHA256: String(repeating: "b", count: 64))
        let sequence = BackupRuntimeInspectionSequence([Self.runtime, changed])
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
            processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let altered = ProfileBrowserDataBackupService(paths: paths, processes: manager, scope: BackupCompatibilityScopeStore(backend: backend),
            inspectRuntime: { sequence.next() })
        do { _ = try await altered.restore(profileID: profile.id, expectedRevision: profile.revision, archive: archive, password: password); Issue.record("Replaced runtime accepted") }
        catch { #expect(error as? BrowserDataBackupStorageError == .incompatibleContext) }
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
        #expect(try fs.contentsOfDirectory(atPath: paths.profileDirectory(for: profile.id).path).filter { $0.hasPrefix(".neantik-backup-restore-") }.isEmpty)
        #expect(try Data(contentsOf: paths.browserDataDirectory(for: profile.id).appendingPathComponent("own-value")) == Data("original owned data".utf8))
    }

    @Test func scopeReplacementDuringPendingPublicationKeepsFenceAndFreshRecoveryRollsBack() async throws {
        let (paths, _, profile, service, backend) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let archive = paths.rootDirectory.appendingPathComponent("own.nabackup")
        _ = try await service.export(profileID: profile.id, expectedRevision: profile.revision, destination: archive, password: password)
        let hook = LateBackupInventoryScopeChange(backend)
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
            processInventoryProvider: { hook.capture() })
        let altered = ProfileBrowserDataBackupService(paths: paths, processes: manager, scope: BackupCompatibilityScopeStore(backend: backend), inspectRuntime: { Self.runtime })
        do { _ = try await altered.restore(profileID: profile.id, expectedRevision: profile.revision, archive: archive, password: password); Issue.record("Late compatibility change bypassed durable boundary") }
        catch { #expect(error as? BrowserDataBackupStorageError == .incompatibleContext) }
        #expect(hook.didChange)
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory) }
        // Missing/mismatched scope cannot be silently repaired by recovery.
        do { _ = try await service.recoverPending(); Issue.record("Mismatched scope recovered") } catch {}
        #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory) }
        backend.replace(Data(repeating: 9, count: 32))
        let preview = try await service.inspectPendingRecovery()
        let pendingMain = try Data(contentsOf: paths.profilesFile)
        let pendingPrevious = try Data(contentsOf: paths.profilesBackupFile)
        let context = preview.context
        let foreignContext = EncryptedBackupArchive.Manifest(profileID: UUID(), identitySHA256: context.identitySHA256,
            runtimeExecutableSHA256: context.runtimeExecutableSHA256, runtimeFrameworkSHA256: context.runtimeFrameworkSHA256,
            runtimeVersion: context.runtimeVersion, compatibilityScopeSHA256: context.compatibilityScopeSHA256, entries: context.entries)
        for wrong in [BrowserDataRestoreTransaction.RecoveryPreview(context: foreignContext, retainedTree: preview.retainedTree),
                      .init(context: context, retainedTree: preview.retainedTree.deletingLastPathComponent().appendingPathComponent("foreign-stage"))] {
            do { _ = try await service.recoverPending(expected: wrong); Issue.record("Different profile/transaction replaced the confirmed recovery") }
            catch { #expect(error as? BrowserDataBackupStorageError == .incompatibleContext) }
            #expect(try Data(contentsOf: paths.profilesFile) == pendingMain)
            #expect(try Data(contentsOf: paths.profilesBackupFile) == pendingPrevious)
            #expect(throws: BrowserDataRestoreError.pending) { try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory) }
        }
        let result = try await service.recoverPending(expected: preview)
        #expect(!result.restored)
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
    }

    @Test func corruptPendingIntentRemainsRecoveryRequiredForUI() async throws {
        let (paths, _, _, service, _) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        #expect(await service.pendingRecoveryRequired() == false)
        try fs.createDirectory(at: paths.rootDirectory.appendingPathComponent(BrowserDataRestoreTransaction.activeName), withIntermediateDirectories: false)
        #expect(await service.pendingRecoveryRequired())
        do { _ = try await service.inspectPendingRecovery(); Issue.record("Corrupt pending journal was inspected as trusted") } catch {}
        #expect(await service.pendingRecoveryRequired())
    }

    @Test func missingRuntimeProofRefusesBeforeScopeCreation() async throws {
        let (paths, _, profile, _, backend) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
            processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let service = ProfileBrowserDataBackupService(paths: paths, processes: manager, scope: BackupCompatibilityScopeStore(backend: backend),
            inspectRuntime: { .init(version: "156.0.8078.12", architectures: ["arm64"], codeSignatureValid: true) })
        do { _ = try await service.export(profileID: profile.id, expectedRevision: profile.revision, destination: paths.rootDirectory.appendingPathComponent("own.nabackup"), password: password); Issue.record("Missing runtime hashes accepted") } catch {}
        #expect(backend.insertionCount == 0)
        #expect(!fs.fileExists(atPath: paths.rootDirectory.appendingPathComponent("own.nabackup").path))
    }

    @Test(arguments: ["export", "restore", "stale-export", "stale-restore"])
    func unsupportedWebKitRefusesBeforeRuntimeScopeOrArchiveWork(operation: String) async throws {
        let (paths, store, profile, _, _) = try fixture(engine: .webkit)
        defer { try? fs.removeItem(at: paths.rootDirectory) }
        _ = try store.upsert(BrowserProfile(name: "Untouched sibling"))
        let tabs = WebKitSessionStore(paths: paths)
        try tabs.save(WebKitSessionSnapshot.capture(profileID: profile.id,
            urls: ["https://example.com/own-backup-qa"], selectedIndex: 0))
        let beforeTabs = try tabs.load(for: profile.id)
        let main = try Data(contentsOf: paths.profilesFile)
        let previous = try Data(contentsOf: paths.profilesBackupFile)
        let file = paths.browserDataDirectory(for: profile.id).appendingPathComponent("own-value")
        let beforeData = try Data(contentsOf: file)
        let archive = paths.rootDirectory.appendingPathComponent("own.nabackup")
        let restoring = operation.hasSuffix("restore")
        let stale = operation.hasPrefix("stale-")
        if restoring { try paths.writePrivateFile(Data("unparsed own archive sentinel".utf8), to: archive) }
        let probe = BackupAdmissionProbe()
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false },
            processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let service = ProfileBrowserDataBackupService(paths: paths, processes: manager,
            scope: BackupCompatibilityScopeStore(backend: probe, random: { Data(repeating: 5, count: 32) }),
            inspectRuntime: { probe.recordRuntimeInspection(); return Self.runtime })
        do {
            if restoring {
                _ = try await service.restore(profileID: profile.id, expectedRevision: profile.revision + (stale ? 1 : 0), archive: archive, password: password)
            } else {
                _ = try await service.export(profileID: profile.id, expectedRevision: profile.revision + (stale ? 1 : 0), destination: archive, password: password)
            }
            Issue.record("Unsupported WebKit backup accepted")
        } catch {
            if stale { #expect(error is BrowserProfileRevisionConflictError) }
            else { #expect(error as? BrowserDataBackupStorageError == .incompatibleContext) }
        }
        #expect(probe.runtimeInspections == 0)
        #expect(probe.scopeReads == 0)
        #expect(probe.scopeInserts == 0)
        #expect(try Data(contentsOf: paths.profilesFile) == main)
        #expect(try Data(contentsOf: paths.profilesBackupFile) == previous)
        #expect(try Data(contentsOf: file) == beforeData)
        #expect(try tabs.load(for: profile.id) == beforeTabs)
        if restoring { #expect(try Data(contentsOf: archive) == Data("unparsed own archive sentinel".utf8)) }
        else { #expect(!fs.fileExists(atPath: archive.path)) }
        try BrowserDataRestoreTransaction.requireNoPending(rootURL: paths.rootDirectory)
        #expect(try fs.contentsOfDirectory(atPath: paths.profileDirectory(for: profile.id).path)
            .filter { $0.hasPrefix(".neantik-backup-restore-") }.isEmpty)
    }
}

private final class BackupAdmissionProbe: BackupCompatibilityScopeBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var runtimeCount = 0, readCount = 0, insertCount = 0
    private var bytes: Data?
    func recordRuntimeInspection() { lock.lock(); defer { lock.unlock() }; runtimeCount += 1 }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; readCount += 1; return bytes }
    func insertIfAbsent(_ value: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; insertCount += 1
        guard bytes == nil else { return false }; bytes = value; return true
    }
    var runtimeInspections: Int { lock.lock(); defer { lock.unlock() }; return runtimeCount }
    var scopeReads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var scopeInserts: Int { lock.lock(); defer { lock.unlock() }; return insertCount }
}

private final class BackupRuntimeInspectionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BrowserRuntimeInspection]
    init(_ values: [BrowserRuntimeInspection]) { self.values = values }
    func next() -> BrowserRuntimeInspection { lock.lock(); defer { lock.unlock() }; return values.count > 1 ? values.removeFirst() : values[0] }
}

private final class LateBackupInventoryScopeChange: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let backend: MemoryBackupScopeBackend
    init(_ backend: MemoryBackupScopeBackend) { self.backend = backend }
    func capture() -> BrowserProcessInventory {
        lock.lock(); defer { lock.unlock() }; count += 1
        if count == 10 { backend.replace(Data(repeating: 7, count: 32)) }
        return BrowserProcessInventory(processes: [:])
    }
    var didChange: Bool { lock.lock(); defer { lock.unlock() }; return count >= 10 }
}
