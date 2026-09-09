import Foundation
import Testing
@testable import NeAntik

struct WorkplaceHomeTests {
    @Test func recentPlacesKeepIdentityAndExcludeArchive() {
        let recent = BrowserProfile(name: "Recent", lastLaunchedAt: Date(timeIntervalSince1970: 300))
        let pinned = BrowserProfile(name: "Pinned", isPinned: true, createdAt: Date(timeIntervalSince1970: 1))
        let old = BrowserProfile(name: "Old", createdAt: Date(timeIntervalSince1970: 2))
        let archived = BrowserProfile(name: "Archive", isPinned: true, isArchived: true)
        let source = [old, archived, recent, pinned]
        let result = WorkplaceHomeProjection.resolve(profiles: source, search: "", limit: 2)
        #expect(result.profiles == [pinned, recent])
        #expect(result.matchCount == 3)
        #expect(source[2].identity == result.profiles[1].identity)
    }

    @Test func localSearchFindsNamesTagsAndNotesWithoutMatchingProxySecrets() {
        let place = BrowserProfile(name: "Клиент", tags: ["Дизайн"], note: "Обновить макет",
                                   proxy: ProxyConfiguration(kind: .https, host: "secret.example", port: 443, username: "private"))
        for query in [" клиент ", "ДИЗАЙН", "макет"] {
            #expect(WorkplaceHomeProjection.resolve(profiles: [place], search: query).profiles == [place])
        }
        for query in ["secret.example", "private"] {
            #expect(WorkplaceHomeProjection.resolve(profiles: [place], search: query).matchCount == 0)
        }
    }

    @Test func openNeverStopsRunningPlaceEvenWithoutRuntime() {
        for state in [BrowserProfileProcessState.managed, .externalVerified, .externalManualOnly] {
            let result = WorkplaceOpenPresentation.resolve(state: state, archived: false, runtime: .missing)
            #expect(result.action == .activate)
            #expect(result.title == "Продолжить")
        }
    }

    @Test func unresolvedProcessesAndUnavailableRuntimeCannotStart() {
        for state in [BrowserProfileProcessState.externalUnverified, .recoveryRequired, .checking] {
            #expect(WorkplaceOpenPresentation.resolve(state: state, archived: false, runtime: .ready).action == .unavailable)
        }
        for runtime in [BrowserRuntimeAvailability.resolving, .missing, .invalid(message: "Invalid")] {
            #expect(WorkplaceOpenPresentation.resolve(state: .stopped, archived: false, runtime: runtime).action == .unavailable)
        }
        #expect(WorkplaceOpenPresentation.resolve(state: .stopped, archived: true, runtime: .ready).action == .unavailable)
        #expect(WorkplaceOpenPresentation.resolve(state: .stopped, archived: false, runtime: .ready, testing: true).action == .unavailable)
        #expect(WorkplaceOpenPresentation.resolve(state: .checking, archived: false, runtime: .ready, preparing: true).action == .cancel)
    }

    @MainActor @Test func unknownPlaceActivationHasNoSideEffects() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BrowserProcessManager(paths: AppPaths(rootDirectory: root), processIdentityValidator: { _ in false })
        var activated = false
        #expect(!manager.focus(profileID: UUID(), using: { _, _ in activated = true; return true }))
        #expect(!activated)
        #expect(manager.runningProfileIDs.isEmpty)
    }

    @MainActor @Test func returningToExternalWindowRechecksIdentityAndLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profile = BrowserProfile(name: "Context A")
        try paths.prepareProfileDirectories(for: profile.id)
        let lock = BrowserProcessLock(pid: 4242, executablePath: "/test/browser",
            browserDataPath: paths.browserDataDirectory(for: profile.id).path, createdAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(encoder.encode(lock), to: paths.lockFile(for: profile.id))
        var inspection = BrowserProcessIdentityInspection.expected
        let manager = BrowserProcessManager(paths: paths,
            processIdentityInspector: { _ in inspection }, processLivenessValidator: { _ in true },
            browserDataProcessInspector: { _ in .absent })
        manager.reconcile(profiles: [profile])
        var count = 0
        let activate: (pid_t, String) -> Bool = { pid, path in
            #expect(pid == 4242)
            #expect(path == "/test/browser")
            count += 1
            return true
        }
        #expect(manager.focus(profileID: profile.id, using: activate))
        #expect(manager.verifiedProfileID(forProcessID: 4242) == profile.id)
        #expect(manager.verifiedProfileID(forProcessID: 9999) == nil)
        inspection = .unknown
        #expect(!manager.focus(profileID: profile.id, using: activate))
        #expect(manager.verifiedProfileID(forProcessID: 4242) == nil)
        inspection = .expected
        try paths.writePrivateFile(Data("{}".utf8), to: paths.lockFile(for: profile.id))
        #expect(!manager.focus(profileID: profile.id, using: activate))
        #expect(count == 1)
    }

    @MainActor @Test func menuRequestsAreConsumedOnceAndDoNotWaitPastDialogs() {
        let navigation = WorkplaceNavigation()
        let profileID = UUID()
        navigation.request(.open(profileID))
        #expect(navigation.consume() == .open(profileID))
        #expect(navigation.consume() == nil)
        navigation.isBlocked = true
        navigation.request(.create)
        #expect(navigation.pending == nil)
        navigation.isBlocked = false
        navigation.request(.open(profileID))
        navigation.isBlocked = true
        #expect(navigation.consume() == nil)
        navigation.isBlocked = false
        #expect(navigation.consume() == nil)
    }
}
