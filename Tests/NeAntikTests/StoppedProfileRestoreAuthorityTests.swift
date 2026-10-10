import Darwin
import Foundation
import Testing
@testable import NeAntik

@MainActor struct StoppedProfileRestoreAuthorityTests {
    private let fs = FileManager.default

    @Test func pendingRecoveryGetsGuardsInOrderAndBorrowCannotEscape() async throws {
        let (paths, id, retained) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        try fs.createDirectory(at: paths.rootDirectory.appendingPathComponent(BrowserDataRestoreTransaction.activeName), withIntermediateDirectories: false)
        try paths.writePrivateFile(Data("unsupported pending metadata".utf8), to: paths.profilesFile)
        #expect(throws: BrowserDataRestoreError.pending) { try paths.withProfilesMetadataGuard {} }
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false }, processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let escaped = try await manager.withVerifiedStoppedProfileRestore(profileID: id, retainedTree: retained) { authority in
            #expect(throws: ProfileProcessBusyError.self) { try paths.withProcessLockGuard(for: id) {} }
            return try paths.withProfilesMetadataGuardForRestore(authority: authority) {
                #expect(throws: ProfileMetadataBusyError.self) { try paths.withProfilesMetadataGuard {} }
                return authority
            }
        }
        #expect(throws: BrowserDataRestoreError.authorityRequired) { try escaped.validate(paths: paths) }
        #expect(throws: BrowserDataRestoreError.authorityRequired) { try paths.withProfilesMetadataGuardForRestore(authority: escaped) {} }
        try paths.withProcessLockGuard(for: id) {}
        #expect(try Data(contentsOf: paths.profilesFile) == Data("unsupported pending metadata".utf8))
    }

    @Test(arguments: ["unknown", "live", "retained"])
    func unavailableOrFoundProcessRefusesWithoutMetadataWrites(kind: String) async throws {
        let (paths, id, retained) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let target = kind == "retained" ? retained : paths.browserDataDirectory(for: id)
        let identity = BrowserProcessKernelIdentity(startSeconds: 123, startMicroseconds: 4)
        let inventory = kind == "unknown" ? BrowserProcessInventory.unavailable : BrowserProcessInventory(
            processes: [1234: BrowserProcessArguments(executablePath: "/private/tmp/NeAntik Browser", arguments: ["NeAntik Browser", "--user-data-dir=\(target.path)"])],
            kernelIdentities: [1234: identity], kernelIdentityRevalidator: { _ in identity })
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false }, processInventoryProvider: { inventory })
        do {
            _ = try await manager.withVerifiedStoppedProfileRestore(profileID: id, retainedTree: retained) { _ in true }
            Issue.record("Restore admitted unavailable/in-use browser root")
        } catch {
            let expected: BrowserProfileDeletionBlockReason = kind == "unknown" ? .inspectionUnavailable : .browserDataInUse
            #expect(error as? BrowserProfileDeletionBlockedError == .init(reason: expected))
        }
        #expect(try paths.privateFileEntryKind(paths.profilesFile) == .missing)
        try paths.withProcessLockGuard(for: id) {}
    }

    @Test(arguments: ["guard", "tombstone", "lease", "other-root"])
    func authorityRechecksReplacementAndLateConstraints(kind: String) async throws {
        let (paths, id, retained) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false }, processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let rejected = try await manager.withVerifiedStoppedProfileRestore(profileID: id, retainedTree: retained) { authority in
            switch kind {
            case "guard":
                let old = paths.lockGuardFile(for: id)
                try FileManager.default.moveItem(at: old, to: old.appendingPathExtension("retained"))
                try paths.writePrivateFile(Data(), to: old)
            case "tombstone": try paths.writePrivateFile(Data(), to: paths.profileDeletionTombstone(for: id))
            case "lease": try paths.writePrivateFile(Data(), to: paths.lockFile(for: id))
            default:
                do { try authority.validate(paths: AppPaths(rootDirectory: paths.rootDirectory.appendingPathComponent("other"))); return false }
                catch { return error as? BrowserDataRestoreError == .authorityRequired }
            }
            do { try authority.validate(paths: paths); return false } catch { return true }
        }
        #expect(rejected)
        #expect(try paths.privateFileEntryKind(paths.profilesFile) == .missing)
    }

    @Test(arguments: ["gui", "stdio", "historical", "missing-kernel", "changed-kernel"])
    func otherManagersRefuseRestoreIncludingHeadlessAndHistorical(kind: String) async throws {
        let (paths, id, retained) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let name = kind == "historical" ? "NeVision" : "NeAntik"
        let identity = BrowserProcessKernelIdentity(startSeconds: 100, startMicroseconds: 10)
        let inventory = BrowserProcessInventory(processes: [4567: BrowserProcessArguments(executablePath: "/private/tmp/Other.app/Contents/MacOS/" + name,
            arguments: [name] + (kind == "stdio" ? ["--mcp-stdio"] : []))],
            kernelIdentities: kind == "missing-kernel" ? [:] : [4567: identity],
            kernelIdentityRevalidator: { _ in kind == "changed-kernel" ? nil : identity })
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false }, processInventoryProvider: { inventory })
        do { _ = try await manager.withVerifiedStoppedProfileRestore(profileID: id, retainedTree: retained) { _ in true }; Issue.record("Other manager bypassed restore exclusivity") }
        catch {
            if kind == "missing-kernel" || kind == "changed-kernel" {
                #expect(error as? BrowserProfileDeletionBlockedError == .init(reason: .inspectionUnavailable))
            } else { #expect(error as? BrowserDataRestoreError == .authorityRequired) }
        }
        #expect(try paths.privateFileEntryKind(paths.profilesFile) == .missing)
        try paths.withProcessLockGuard(for: id) {}
    }

    @Test func managerInventoryDoesNotTreatCurrentWindowOrRuntimeAsAnotherManager() {
        let identity = BrowserProcessKernelIdentity(startSeconds: 100, startMicroseconds: 10)
        let inventory = BrowserProcessInventory(processes: [getpid(): .init(executablePath: "/private/tmp/NeAntik", arguments: ["NeAntik"]),
            4567: .init(executablePath: "/private/tmp/NeAntik Browser", arguments: ["NeAntik Browser"])],
            kernelIdentities: [getpid(): identity, 4567: identity], kernelIdentityRevalidator: { _ in identity })
        #expect(inventory.inspectOtherManagerProcesses() == .absent)
        #expect(BrowserProcessInventory.unavailable.inspectOtherManagerProcesses() == .unknown)
        #expect(BrowserProcessInventory(processes: [:], unreadableLiveProcessExists: true).inspectOtherManagerProcesses() == .unknown)
    }

    @Test func foreignRetainedPathAndAbsentProviderDoNotCreateAuthority() async throws {
        let (paths, id, retained) = try fixture(); defer { try? fs.removeItem(at: paths.rootDirectory) }
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false }, processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        do { _ = try await manager.withVerifiedStoppedProfileRestore(profileID: id, retainedTree: paths.rootDirectory) { _ in true }; Issue.record("Foreign retained root admitted") }
        catch { #expect(error as? BrowserDataRestoreError == .authorityRequired) }
        let unknown = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent })
        do { _ = try await unknown.withVerifiedStoppedProfileRestore(profileID: id, retainedTree: retained) { _ in true }; Issue.record("Absent-only UI inspector became recovery authority") }
        catch { #expect(error as? BrowserProfileDeletionBlockedError == .init(reason: .inspectionUnavailable)) }
    }

    private func fixture() throws -> (AppPaths, UUID, URL) {
        let paths = AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-restore-authority-\(UUID())"))
        try paths.prepareBaseDirectories()
        let id = UUID(); try paths.prepareProfileDirectories(for: id)
        let retained = paths.profileDirectory(for: id).appendingPathComponent(".neantik-backup-restore-\(UUID().uuidString.lowercased())")
        try fs.createDirectory(at: retained, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (paths, id, retained)
    }
}
