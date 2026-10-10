import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProfileCacheMaintenanceTests {
    private final class LateInventory: @unchecked Sendable {
        let lock = NSLock()
        private var late = false
        func set(_ value: Bool) { lock.lock(); late = value; lock.unlock() }
        func capture(browser: URL, kind: String) -> BrowserProcessInventory {
            lock.lock(); let changed = late; lock.unlock()
            guard changed else { return BrowserProcessInventory(processes: [:]) }
            if kind == "unknown" { return .unavailable }
            let identity = BrowserProcessKernelIdentity(startSeconds: 123, startMicroseconds: 4)
            return BrowserProcessInventory(processes: [1234: .init(executablePath: "/private/tmp/Own Browser", arguments: ["Own Browser", "--user-data-dir=" + browser.path])],
                kernelIdentities: [1234: identity], kernelIdentityRevalidator: { _ in identity })
        }
    }
    @Test(arguments: ["live", "unknown", "lease", "tombstone"])
    @MainActor func lateProcessOrLeaseRefusesUnlinkAndFreshAuthorityRecovers(kind: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), profile = BrowserProfile(name: "Own late cache process")
        try paths.prepareBaseDirectories()
        let browser = paths.browserDataDirectory(for: profile.id), protected = try populate(browser), inventory = LateInventory()
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false }, processInventoryProvider: { inventory.capture(browser: browser, kind: kind) })
        await #expect(throws: ProfileCacheError.rollbackRequired.self) {
            try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
                let operation = ProfileCacheMaintenance(browserData: browser, fault: { point in
                    if case .beforeRemoval = point {
                        if kind == "lease" { try paths.writePrivateFile(Data(), to: paths.lockFile(for: profile.id)) }
                        else if kind == "tombstone" { try paths.writePrivateFile(Data(), to: paths.profileDeletionTombstone(for: profile.id)) }
                        else { inventory.set(true) }
                    }
                }, authority: authority)
                return try operation.clear()
            }
        }
        #expect(FileManager.default.fileExists(atPath: browser.appendingPathComponent("Default/.neantik-cache-maintenance.json").path))
        inventory.set(false)
        if kind == "lease" { try FileManager.default.removeItem(at: paths.lockFile(for: profile.id)) }
        if kind == "tombstone" { try FileManager.default.removeItem(at: paths.profileDeletionTombstone(for: profile.id)) }
        let recovered = try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
            try ProfileCacheMaintenance(browserData: browser, authority: authority).recover()
        }
        #expect(recovered.restoredRoots == 2 && !recovered.cacheMayAlreadyBeRemoved)
        #expect(try ProfileCacheMaintenance(browserData: browser).estimate().bytes == 14)
        for (path, bytes) in protected { #expect(try Data(contentsOf: browser.appendingPathComponent(path)) == bytes) }
    }
    @Test @MainActor func borrowedAuthorityExpiresAndRejectsAnotherBrowserData() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), profile = BrowserProfile(name: "Own borrowed cache authority")
        try paths.prepareBaseDirectories()
        let browser = paths.browserDataDirectory(for: profile.id)
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false }, processInventoryProvider: { BrowserProcessInventory(processes: [:]) })
        let retained = try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
            try authority.validate(browserData: browser)
            #expect(throws: ProfileProcessBusyError.self) { try authority.validate(browserData: root.appendingPathComponent("other")) }
            return authority
        }
        #expect(throws: ProfileProcessBusyError.self) { try retained.validate(browserData: browser) }
        try paths.withProcessLockGuard(for: profile.id) {}
    }
    @Test(arguments: ["stage", "removal", "recorded"])
    @MainActor func replacedMaintenanceGuardBeforeRemovalMustPreserveCache(point: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), profile = BrowserProfile(name: "Own late cache authority")
        try paths.prepareBaseDirectories()
        let browser = paths.browserDataDirectory(for: profile.id), protected = try populate(browser)
        let guardURL = paths.lockGuardFile(for: profile.id), held = root.appendingPathComponent("held-maintenance-guard")
        let manager = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent })
        let operation = ProfileCacheMaintenance(browserData: browser, fault: { commit in
            let replace: Bool
            switch commit {
            case .beforeStage(0): replace = point == "stage"
            case .beforeRemoval: replace = point == "removal"
            case .removalRecorded: replace = point == "recorded"
            default: replace = false
            }
            if replace {
                try FileManager.default.moveItem(at: guardURL, to: held)
                try paths.writePrivateFile(Data(), to: guardURL)
            }
        })
        await #expect(throws: ProfileCacheError.rollbackRequired.self) {
            try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
                var operation = operation; operation.authority = authority
                return try operation.clear()
            }
        }
        let parent = browser.appendingPathComponent("Default")
        let enumerator = try #require(FileManager.default.enumerator(at: parent, includingPropertiesForKeys: [.isRegularFileKey]))
        var retained = 0
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let bytes = try Data(contentsOf: url)
                if bytes == Data("cache-data".utf8) || bytes == Data("code".utf8) { retained += 1 }
            }
        }
        #expect(retained == 2)
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".neantik-cache-maintenance.json").path))
        for (path, bytes) in protected { #expect(try Data(contentsOf: browser.appendingPathComponent(path)) == bytes) }
    }
    @Test func movedBrowserDataPreservesHeldCacheAndForeignReplacement() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData"), held = root.appendingPathComponent("HeldBrowserData")
        let protected = try populate(browser)
        let operation = ProfileCacheMaintenance(browserData: browser, fault: { point in
            if case .beforeRemoval = point {
                try FileManager.default.moveItem(at: browser, to: held)
                try write(Data("foreign cache".utf8), to: browser.appendingPathComponent("Default/Cache/preserve"))
            }
        })
        #expect(throws: ProfileCacheError.rollbackRequired.self) { try operation.clear() }
        #expect(try Data(contentsOf: browser.appendingPathComponent("Default/Cache/preserve")) == Data("foreign cache".utf8))
        for (path, bytes) in protected { #expect(try Data(contentsOf: held.appendingPathComponent(path)) == bytes) }
        try FileManager.default.moveItem(at: browser, to: root.appendingPathComponent("ForeignBrowserData"))
        try FileManager.default.moveItem(at: held, to: browser)
        #expect(try ProfileCacheMaintenance(browserData: browser).recover().restoredRoots == 2)
        #expect(try ProfileCacheMaintenance(browserData: browser).estimate().bytes == 14)
    }
    @Test @MainActor func recoveryAuthorityLossRetainsAllUnrenamedStages() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), profile = BrowserProfile(name: "Own cache recovery authority")
        try paths.prepareBaseDirectories()
        let browser = paths.browserDataDirectory(for: profile.id)
        _ = try populate(browser)
        #expect(throws: ProfileCacheError.partiallyRemoved.self) {
            try ProfileCacheMaintenance(browserData: browser, fault: { if case .removingRoot(0) = $0 { throw CocoaError(.fileWriteOutOfSpace) } }).clear()
        }
        let inventory = LateInventory()
        let manager = BrowserProcessManager(paths: paths, processIdentityInspector: { _ in .unrelated }, processLivenessValidator: { _ in false }, processInventoryProvider: { inventory.capture(browser: browser, kind: "unknown") })
        await #expect(throws: (any Error).self) {
            try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
                try ProfileCacheMaintenance(browserData: browser, fault: { if case .recoveryBeforeRename(0) = $0 { inventory.set(true) } }, authority: authority).recover()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: browser.appendingPathComponent("Default/Cache").path))
        #expect(!FileManager.default.fileExists(atPath: browser.appendingPathComponent("Default/Code Cache").path))
        inventory.set(false)
        let recovered = try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { authority in
            try ProfileCacheMaintenance(browserData: browser, authority: authority).recover()
        }
        #expect(recovered.restoredRoots == 2)
        #expect(try ProfileCacheMaintenance(browserData: browser).estimate().bytes == 14)
    }
    @Test func onlyTwoCacheRootsAreRemovedAndDataIsPreserved() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData")
        let protected = try populate(browser)
        let operation = ProfileCacheMaintenance(browserData: browser)
        let size = try operation.estimate()
        #expect(size.files == 2 && size.bytes == 14 && size.directories == 3)
        #expect(try operation.clear() == size)
        #expect(try operation.estimate().files == 0)
        for (path, data) in protected { #expect(try Data(contentsOf: browser.appendingPathComponent(path)) == data) }
    }

    @Test func macOSMirrorUsesCachesInsteadOfBrowserData() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Library/Application Support")
        let caches = root.appendingPathComponent("Library/Caches")
        let browser = support.appendingPathComponent("NeAntik/Profiles/fixture/BrowserData")
        let operation = ProfileCacheMaintenance(browserData: browser, applicationSupport: support, libraryCaches: caches)
        #expect(operation.cacheParent.path == caches.appendingPathComponent("NeAntik/Profiles/fixture/BrowserData/Default").path)
        let protected = try populate(browser)
        try write(Data("mirror".utf8), to: operation.cacheParent.appendingPathComponent("Cache/Cache_Data/item"))
        #expect(try operation.estimate().bytes == 6)
        _ = try operation.clear()
        #expect(try Data(contentsOf: browser.appendingPathComponent("Default/Cache/Cache_Data/item")) == Data("cache-data".utf8))
        for (path, data) in protected { #expect(try Data(contentsOf: browser.appendingPathComponent(path)) == data) }
    }

    @Test(arguments: [0, 1, 2]) func injectedStageFailuresRollBackBothRoots(point: Int) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData")
        _ = try populate(browser)
        let operation = ProfileCacheMaintenance(browserData: browser, fault: { stage in
            switch stage {
            case .staged(0) where point == 0, .beforeStage(1) where point == 1, .beforeRemoval where point == 2:
                throw CocoaError(.fileWriteOutOfSpace)
            default: break
            }
        })
        #expect(throws: (any Error).self) { try operation.clear() }
        #expect(try ProfileCacheMaintenance(browserData: browser).estimate().bytes == 14)
        let entries = try FileManager.default.contentsOfDirectory(atPath: browser.appendingPathComponent("Default").path)
        #expect(!entries.contains(where: { $0.hasPrefix(".neantik-cache-clearing-") }))
    }

    @Test(arguments: ["symlink", "hardlink", "fifo", "ancestor"]) func unsafeObjectsAreRefusedBeforeAnyDeletion(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData")
        _ = try populate(browser)
        let target = root.appendingPathComponent("preserve")
        try Data("outside".utf8).write(to: target)
        let bad = browser.appendingPathComponent("Default/Code Cache/bad")
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: target)
        case "hardlink": try FileManager.default.linkItem(at: target, to: bad)
        case "fifo": try #require(mkfifo(bad.path, 0o600) == 0)
        default:
            try FileManager.default.moveItem(at: browser.appendingPathComponent("Default"), to: root.appendingPathComponent("Moved"))
            try FileManager.default.createSymbolicLink(at: browser.appendingPathComponent("Default"), withDestinationURL: root.appendingPathComponent("Moved"))
        }
        #expect(throws: (any Error).self) { try ProfileCacheMaintenance(browserData: browser).clear() }
        #expect(try Data(contentsOf: target) == Data("outside".utf8))
        #expect(try Data(contentsOf: browser.appendingPathComponent("Default/Cache/Cache_Data/item")) == Data("cache-data".utf8))
    }

    @Test func limitsOverridesAndCorruptPreferencesRefuse() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData")
        _ = try populate(browser)
        for limited in [ProfileCacheMaintenance(browserData: browser, maximumEntries: 1), ProfileCacheMaintenance(browserData: browser, maximumBytes: 12)] {
            #expect(throws: ProfileCacheError.limitExceeded) { try limited.clear() }
        }
        let prefs = browser.appendingPathComponent("Default/Preferences")
        for data in [Data("{\"browser\":{\"disk_cache_dir\":\"/outside\"}}".utf8), Data("broken".utf8)] {
            try data.write(to: prefs)
            #expect(throws: ProfileCacheError.unsupportedLocation) { try ProfileCacheMaintenance(browserData: browser).clear() }
        }
        #expect(try Data(contentsOf: browser.appendingPathComponent("Default/Cache/Cache_Data/item")) == Data("cache-data".utf8))
    }

    @Test func directoryReplacementAfterScanIsNotDeletedOrOverwritten() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData")
        _ = try populate(browser)
        let cache = browser.appendingPathComponent("Default/Cache")
        let held = root.appendingPathComponent("held-cache")
        let operation = ProfileCacheMaintenance(browserData: browser, fault: { stage in
            if case .beforeStage(0) = stage {
                try FileManager.default.moveItem(at: cache, to: held)
                try write(Data("replacement".utf8), to: cache.appendingPathComponent("preserve"))
            }
        })
        #expect(throws: ProfileCacheError.changed) { try operation.clear() }
        #expect(try Data(contentsOf: cache.appendingPathComponent("preserve")) == Data("replacement".utf8))
        #expect(try Data(contentsOf: held.appendingPathComponent("Cache_Data/item")) == Data("cache-data".utf8))
    }

    @Test func partialUnlinkRefusesFalseEmptySuccessAndPreservesForeignStages() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData")
        _ = try populate(browser)
        let operation = ProfileCacheMaintenance(browserData: browser, fault: { stage in
            if case .removingRoot(1) = stage { throw CocoaError(.fileWriteNoPermission) }
        })
        #expect(throws: ProfileCacheError.partiallyRemoved) { try operation.clear() }
        #expect(throws: ProfileCacheError.rollbackRequired) { try ProfileCacheMaintenance(browserData: browser).estimate() }
        #expect(throws: ProfileCacheError.rollbackRequired) { try ProfileCacheMaintenance(browserData: browser).clear() }
        let foreign = browser.appendingPathComponent("Default/.neantik-cache-clearing-foreign/preserve")
        try write(Data("foreign-stage".utf8), to: foreign)
        #expect(throws: ProfileCacheError.rollbackRequired) { try ProfileCacheMaintenance(browserData: browser).clear() }
        #expect(try Data(contentsOf: foreign) == Data("foreign-stage".utf8))
    }

    @Test func changedLaterStagedRootRefusesBeforeDeletingFirstRoot() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData")
        _ = try populate(browser)
        let parent = browser.appendingPathComponent("Default")
        let operation = ProfileCacheMaintenance(browserData: browser, fault: { stage in
            if case .beforeRemoval = stage {
                let entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                let code = try #require(entries.first {
                    $0.lastPathComponent.hasPrefix(".neantik-cache-clearing-") &&
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("item").path)
                })
                try write(Data("foreign-replacement".utf8), to: code.appendingPathComponent("item"))
            }
        })
        #expect(throws: ProfileCacheError.rollbackRequired) { try operation.clear() }
        #expect(try Data(contentsOf: browser.appendingPathComponent("Default/Cache/Cache_Data/item")) == Data("cache-data".utf8))
        let stages = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        let preserved = stages.contains { (try? Data(contentsOf: $0.appendingPathComponent("item"))) == Data("foreign-replacement".utf8) }
        #expect(preserved)
    }

    @Test func cancellationAfterStageRollsBackBothCaches() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData")
        _ = try populate(browser)
        let barrier = Barrier()
        let operation = ProfileCacheMaintenance(browserData: browser, fault: { stage in
            if case .staged(0) = stage {
                barrier.started = true
                _ = barrier.release.wait(timeout: .now() + 5)
            }
        })
        let task = Task.detached { try operation.clear() }
        defer { barrier.release.signal() }
        for _ in 0..<100 where !barrier.started { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(barrier.started)
        task.cancel(); barrier.release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try ProfileCacheMaintenance(browserData: browser).estimate().bytes == 14)
    }

    @Test @MainActor func stoppedMaintenanceRetainsAuthorityAcrossAwaitAndReleasesOnFailure() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Own cache fixture")
        let manager = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent })
        let barrier = Barrier()
        let operation = Task {
            try await manager.withVerifiedStoppedProfileMaintenance(profile: profile) { _ in
                barrier.started = true
                _ = barrier.release.wait(timeout: .now() + 5)
                throw CocoaError(.fileWriteNoPermission)
            } as Void
        }
        defer { barrier.release.signal() }
        for _ in 0..<100 where !barrier.started { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(barrier.started)
        #expect(throws: ProfileProcessBusyError.self) { try paths.withProcessLockGuard(for: profile.id) {} }
        barrier.release.signal()
        do { try await operation.value; Issue.record("Worker fault must propagate") } catch { }
        #expect(throws: Never.self) { try paths.withProcessLockGuard(for: profile.id) {} }
    }

    @Test @MainActor func unknownProcessAndStaleMetadataRefuseMaintenance() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let saved = try store.upsert(BrowserProfile(name: "Own stale cache fixture"))
        let unknown = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .unknown })
        await #expect(throws: (any Error).self) { try await unknown.withVerifiedStoppedProfileMaintenance(profile: saved) { _ in Issue.record("Unknown must refuse"); return true } }
        var changed = saved; changed.name = "new metadata"
        _ = try store.upsert(changed)
        let manager = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent }, validatesPersistedProfiles: true)
        await #expect(throws: BrowserProfileRevisionConflictError.self) { try await manager.withVerifiedStoppedProfileMaintenance(profile: saved) { _ in Issue.record("Stale snapshot must refuse"); return true } }
        #expect(throws: Never.self) { try paths.withProcessLockGuard(for: saved.id) {} }
    }

    @Test func partialDeletionRecoveryReturnsOnlyRemainingCacheAndPreservesSiteData() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData"), protected = try populate(browser)
        let interrupted = ProfileCacheMaintenance(browserData: browser, fault: { if case .removingRoot(1) = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        #expect(throws: ProfileCacheError.partiallyRemoved) { try interrupted.clear() }
        let operation = ProfileCacheMaintenance(browserData: browser)
        #expect(throws: ProfileCacheError.rollbackRequired) { try operation.estimate() }
        #expect(try operation.recover() == .init(restoredRoots: 1, cacheMayAlreadyBeRemoved: true))
        #expect(try operation.estimate().bytes == 4)
        #expect(try Data(contentsOf: browser.appendingPathComponent("Default/Code Cache/item")) == Data("code".utf8))
        for (path, bytes) in protected { #expect(try Data(contentsOf: browser.appendingPathComponent(path)) == bytes) }
        #expect(throws: ProfileCacheError.rollbackRequired) { try operation.recover() }
        #expect(try operation.clear().bytes == 4)
    }

    @Test func interruptedRecoveryIsRetryableAndNeverDeletesRemainingBytes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData"); _ = try populate(browser)
        let interrupted = ProfileCacheMaintenance(browserData: browser, fault: { if case .removingRoot(0) = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        #expect(throws: ProfileCacheError.partiallyRemoved) { try interrupted.clear() }
        let recovery = ProfileCacheMaintenance(browserData: browser, fault: { if case .recoveryRenamed(0) = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        #expect(throws: (any Error).self) { try recovery.recover() }
        #expect(try Data(contentsOf: browser.appendingPathComponent("Default/Cache/Cache_Data/item")) == Data("cache-data".utf8))
        let operation = ProfileCacheMaintenance(browserData: browser)
        #expect(try operation.recover().restoredRoots == 1)
        #expect(try operation.estimate().bytes == 14)
    }

    @Test(arguments: ["schema", "parent", "oversize", "symlink", "collision", "foreign-stage"])
    func invalidRecoveryRefusesAllRenamesAndPreservesForeignEntries(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData"); _ = try populate(browser)
        let interrupted = ProfileCacheMaintenance(browserData: browser, fault: { if case .removingRoot(0) = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        #expect(throws: ProfileCacheError.partiallyRemoved) { try interrupted.clear() }
        let parent = browser.appendingPathComponent("Default"), journal = parent.appendingPathComponent(".neantik-cache-maintenance.json")
        let entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        let stages = entries.filter { $0.lastPathComponent.hasPrefix(".neantik-cache-clearing-") }
        try #require(stages.count == 2)
        switch kind {
        case "schema", "parent":
            let bytes = try Data(contentsOf: journal)
            var object = try #require(JSONSerialization.jsonObject(with: bytes.dropFirst(10)) as? [String: Any])
            if kind == "schema" { object["schema"] = 99 } else {
                var reference = try #require(object["parent"] as? [String: Any]); reference["inode"] = 0; object["parent"] = reference
            }
            var changed = Data(bytes.prefix(10)); changed.append(try JSONSerialization.data(withJSONObject: object)); try changed.write(to: journal)
        case "oversize": try Data(repeating: 0, count: 16_385).write(to: journal)
        case "symlink":
            try FileManager.default.moveItem(at: journal, to: root.appendingPathComponent("held-journal"))
            try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: root.appendingPathComponent("held-journal"))
        case "collision": try write(Data("foreign".utf8), to: parent.appendingPathComponent("Cache/preserve"))
        default: try write(Data("foreign".utf8), to: parent.appendingPathComponent(".neantik-cache-clearing-foreign/preserve"))
        }
        #expect(throws: (any Error).self) { try ProfileCacheMaintenance(browserData: browser).recover() }
        for stage in stages { #expect(FileManager.default.fileExists(atPath: stage.path)) }
        if kind == "collision" { #expect(try Data(contentsOf: parent.appendingPathComponent("Cache/preserve")) == Data("foreign".utf8)) }
        if kind == "foreign-stage" { #expect(try Data(contentsOf: parent.appendingPathComponent(".neantik-cache-clearing-foreign/preserve")) == Data("foreign".utf8)) }
    }

    @Test(arguments: [0, 1]) func journalWriteAndPhaseFaultsRollBackWithoutLeavingIntent(point: Int) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData"); _ = try populate(browser)
        let operation = ProfileCacheMaintenance(browserData: browser, fault: { stage in
            switch stage {
            case .journalCreated where point == 0, .removalRecorded where point == 1: throw CocoaError(.fileWriteOutOfSpace)
            default: break
            }
        })
        #expect(throws: (any Error).self) { try operation.clear() }
        #expect(try ProfileCacheMaintenance(browserData: browser).estimate().bytes == 14)
        #expect(!FileManager.default.fileExists(atPath: browser.appendingPathComponent("Default/.neantik-cache-maintenance.json").path))
    }

    @Test(arguments: [false, true]) func inPlaceJournalReplacementDuringRecoveryRefusesRename(preserveTimeAndSize: Bool) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData"); _ = try populate(browser)
        let interrupted = ProfileCacheMaintenance(browserData: browser, fault: { if case .removingRoot(0) = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        #expect(throws: ProfileCacheError.partiallyRemoved) { try interrupted.clear() }
        let journal = browser.appendingPathComponent("Default/.neantik-cache-maintenance.json")
        let before = try Data(contentsOf: journal)
        let recovery = ProfileCacheMaintenance(browserData: browser, fault: { stage in
            if case .recoveryBeforeRename(0) = stage {
                var original = stat(); guard lstat(journal.path, &original) == 0 else { throw CocoaError(.fileReadUnknown) }
                let changed = preserveTimeAndSize
                    ? Data(String(decoding: before, as: UTF8.self).replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2").utf8)
                    : Data("foreign changed intent".utf8)
                try changed.write(to: journal)
                if preserveTimeAndSize {
                    let times = [original.st_atimespec, original.st_mtimespec]
                    guard times.withUnsafeBufferPointer({ utimensat(AT_FDCWD, journal.path, $0.baseAddress, 0) }) == 0 else { throw CocoaError(.fileWriteUnknown) }
                    var after = stat(); guard lstat(journal.path, &after) == 0 else { throw CocoaError(.fileReadUnknown) }
                    #expect(changed.count == before.count && changed != before)
                    #expect(original.st_ino == after.st_ino && original.st_size == after.st_size)
                    #expect(original.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && original.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
                }
            }
        })
        #expect(throws: ProfileCacheError.rollbackRequired) { try recovery.recover() }
        #expect(!FileManager.default.fileExists(atPath: browser.appendingPathComponent("Default/Cache").path))
        #expect(try Data(contentsOf: journal) != before)
        let entries = try FileManager.default.contentsOfDirectory(atPath: browser.appendingPathComponent("Default").path)
        #expect(entries.filter { $0.hasPrefix(".neantik-cache-clearing-") }.count == 2)
    }

    @Test func stageReplacementBetweenObservationAndCaptureIsNotAdopted() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData"); _ = try populate(browser)
        let interrupted = ProfileCacheMaintenance(browserData: browser, fault: { if case .removingRoot(0) = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        #expect(throws: ProfileCacheError.partiallyRemoved) { try interrupted.clear() }
        let parent = browser.appendingPathComponent("Default"), held = root.appendingPathComponent("held-stage")
        let stages = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        let stage = try #require(stages.first { $0.lastPathComponent.hasSuffix("-0") })
        let recovery = ProfileCacheMaintenance(browserData: browser, fault: { point in
            if case .recoveryObserved(0) = point {
                try FileManager.default.moveItem(at: stage, to: held)
                try write(Data("foreign".utf8), to: stage.appendingPathComponent("preserve"))
            }
        })
        #expect(throws: ProfileCacheError.rollbackRequired) { try recovery.recover() }
        #expect(try Data(contentsOf: stage.appendingPathComponent("preserve")) == Data("foreign".utf8))
        #expect(try Data(contentsOf: held.appendingPathComponent("Cache_Data/item")) == Data("cache-data".utf8))
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Cache").path))
    }

    @Test func preparedIntentWithOneOriginalAndOneStageRecoversWithoutDeletion() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let browser = root.appendingPathComponent("BrowserData"); _ = try populate(browser)
        let interrupted = ProfileCacheMaintenance(browserData: browser, fault: { if case .removingRoot(0) = $0 { throw CocoaError(.fileWriteOutOfSpace) } })
        #expect(throws: ProfileCacheError.partiallyRemoved) { try interrupted.clear() }
        let parent = browser.appendingPathComponent("Default"), journal = parent.appendingPathComponent(".neantik-cache-maintenance.json")
        let stages = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        let firstStage = try #require(stages.first { $0.lastPathComponent.hasSuffix("-0") })
        // Reconstruct a process-crash state from durable intent: one rename
        // happened, the second did not, and unlink never began. This is a
        // filesystem-state control, not a claim that a process was killed.
        try FileManager.default.moveItem(at: firstStage, to: parent.appendingPathComponent("Cache"))
        var bytes = try Data(contentsOf: journal); bytes[8] = 48; try bytes.write(to: journal)
        let operation = ProfileCacheMaintenance(browserData: browser)
        #expect(try operation.recover() == .init(restoredRoots: 1, cacheMayAlreadyBeRemoved: false))
        #expect(try operation.estimate().bytes == 14)
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("neantik-cache-fixture." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func populate(_ browser: URL) throws -> [String: Data] {
        try write(Data("cache-data".utf8), to: browser.appendingPathComponent("Default/Cache/Cache_Data/item"))
        try write(Data("code".utf8), to: browser.appendingPathComponent("Default/Code Cache/item"))
        let protected = Dictionary(uniqueKeysWithValues: ["Default/Network/Cookies", "Default/IndexedDB/item", "Default/Local Storage/item", "Default/Service Worker/Database/item", "Default/Service Worker/CacheStorage/item", "Default/Extensions/item", "Default/Sessions/item"].map { ($0, Data(("preserve:" + $0).utf8)) })
        for (path, bytes) in protected { try write(bytes, to: browser.appendingPathComponent(path)) }
        return protected
    }
}

private func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

private final class Barrier: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var started: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
    let release = DispatchSemaphore(value: 0)
}
