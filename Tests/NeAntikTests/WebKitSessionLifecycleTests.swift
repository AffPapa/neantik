import AppKit
import Foundation
import Testing
import WebKit
@testable import NeAntik

private final class OwnedSessionWriteSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var denied = true
    func check() throws { lock.lock(); defer { lock.unlock() }; if denied { throw WebKitSessionError.unavailable } }
    func allow() { lock.lock(); denied = false; lock.unlock() }
}

@Suite(.serialized) @MainActor struct WebKitSessionLifecycleTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("neantik-session-live-owned-\(UUID())").resolvingSymlinksInPath()
    }
    private func base() throws -> URL {
        let value = try #require(ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_SESSION_FIXTURE_URL"])
        let url = try #require(URL(string: value))
        guard url.scheme == "http", url.host == "127.0.0.1", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw WebKitProfileError.unsupported("Session fixture must be owned loopback HTTP")
        }
        return url
    }
    private func loaded(_ view: WKWebView, _ expected: URL, blank: Bool = false) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if view.url == expected, !view.isLoading {
                if blank { return }
                if (try? await view.evaluateJavaScript("window.neantikOwnSessionFixture === true")) as? Bool == true { return }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebKitProfileError.unsupported("Own session fixture did not settle")
    }
    private func settled(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(predicate())
    }
    private func browser(_ profile: BrowserProfile, _ paths: AppPaths, store: WebKitSessionStore? = nil,
                         onError: (() -> Void)? = nil, onClose: @escaping () -> Void) throws -> WebKitProfileBrowser {
        let sessions = store ?? WebKitSessionStore(paths: paths)
        let lease = try paths.acquireWebKitSessionGuard(for: profile.id)
        do {
            let fence = try paths.acquireWebKitMetadataGuard(for: profile.id)
            let saved = profile.startupMode == .restoreSession ? try sessions.load(for: profile.id) : nil
            return try WebKitProfileBrowser(profile: profile, lease: lease, metadataLease: fence,
                sessionStore: sessions, restoredSession: saved, onSessionSaveError: onError, onClose: onClose)
        } catch { lease.release(); throw error }
    }
    private func remove(_ ids: [UUID]) async throws {
        // Only known IDs created by this scenario. No global store inventory.
        try await Task.sleep(for: .milliseconds(300))
        for id in ids {
            let error: Error? = await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: id) { continuation.resume(returning: $0) }
            }
            #expect(error == nil, "Owned synthetic website store must be released before cleanup")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_SESSION_LIVE"] == "1"))
    func actualAutosavePersistsCommittedHistoryAndSelectionWhileWindowRemainsOpen() async throws {
        let ids = try await autosaveScenario(); try await remove(ids)
    }
    private func autosaveScenario() async throws -> [UUID] {
        _ = NSApplication.shared
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory), profiles = ProfileStore(paths: paths)
        let sessions = WebKitSessionStore(paths: paths), origin = try base()
        let one = origin.appendingPathComponent("one"), two = origin.appendingPathComponent("two")
        let updated = try #require(URL(string: origin.absoluteString + "/two?owned=checkpoint#committed"))
        let a = try profiles.upsert(BrowserProfile(name: "Own autosave", startURL: one.absoluteString, startupMode: .restoreSession, engine: .webkit))
        let b = try profiles.upsert(BrowserProfile(name: "Own opt-out", startURL: one.absoluteString, engine: .webkit))
        var closedA = false, closedB = false
        var first: WebKitProfileBrowser? = try browser(a, paths, onClose: { closedA = true })
        var second: WebKitProfileBrowser? = try browser(b, paths, onClose: { closedB = true })
        defer { first?.close(); second?.close() }
        first?.show(); second?.show()
        try await loaded(try #require(first?.webView), one)
        try await loaded(try #require(second?.webView), one)
        let next = try #require(first?.openTab(at: two))
        try await loaded(next, two)
        _ = try await next.evaluateJavaScript("history.pushState({}, '', '/two?owned=checkpoint#committed')")
        try await loaded(next, updated)
        // A fresh descriptor read before close catches the old close-only
        // implementation: it cannot satisfy these persisted tab assertions.
        try await settled {
            let saved = try? sessions.load(for: a.id)
            return saved?.urls == [one.absoluteString, updated.absoluteString] && saved?.selectedIndex == 1
        }
        #expect(!closedA && !closedB)
        #expect(try sessions.load(for: b.id) == nil, "Opt-out must never create a session file")
        next.load(URLRequest(url: origin.appendingPathComponent("pending")))
        try await Task.sleep(for: .milliseconds(600))
        #expect(try sessions.load(for: a.id)?.urls == [one.absoluteString, updated.absoluteString])
        first?.closeTab(try #require(first?.selectedTabID))
        try await settled { (try? sessions.load(for: a.id)?.urls) == [one.absoluteString] }
        first?.close(); second?.close(); try await settled { closedA && closedB }
        first = nil; second = nil
        #expect(try sessions.load(for: a.id)?.urls == [one.absoluteString])
        return [a.id, b.id]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_SESSION_LIVE"] == "1"))
    func actualWindowsRestoreOrderSelectionQueriesAndSameDocumentState() async throws {
        let ids = try await restoreScenario(); try await remove(ids)
    }
    private func restoreScenario() async throws -> [UUID] {
        _ = NSApplication.shared
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory), profiles = ProfileStore(paths: paths), sessions = WebKitSessionStore(paths: paths)
        let origin = try base(), one = origin.appendingPathComponent("one")
        let two = try #require(URL(string: origin.absoluteString + "/two?owned=two#initial"))
        let updated = try #require(URL(string: origin.absoluteString + "/two?owned=updated#state"))
        let three = origin.appendingPathComponent("three")
        let a = try profiles.upsert(BrowserProfile(name: "Own restore A", startURL: one.absoluteString, startupMode: .restoreSession, engine: .webkit))
        let b = try profiles.upsert(BrowserProfile(name: "Own restore B", startURL: three.absoluteString, startupMode: .restoreSession, engine: .webkit))
        var closedA = false, closedB = false
        var first: WebKitProfileBrowser? = try browser(a, paths, onClose: { closedA = true })
        var second: WebKitProfileBrowser? = try browser(b, paths, onClose: { closedB = true })
        defer { first?.close(); second?.close() }
        first?.show(); second?.show()
        try await loaded(try #require(first?.webView), one); try await loaded(try #require(second?.webView), three)
        _ = try await first?.webView.evaluateJavaScript("localStorage.setItem('owned-session-marker','A')")
        #expect(try await second?.webView.evaluateJavaScript("localStorage.getItem('owned-session-marker')") as? String == nil)
        let next = try #require(first?.openTab(at: two)); let selected = try #require(first?.selectedTabID)
        try await loaded(next, two)
        let blank = try #require(first?.openTab(at: URL(string: "about:blank")!))
        try await loaded(blank, URL(string: "about:blank")!, blank: true)
        first?.selectTab(selected)
        _ = try await next.evaluateJavaScript("history.pushState({}, '', '/two?owned=updated#state')")
        try await loaded(next, updated)
        // The delayed provisional navigation must not replace the committed
        // History API address when this window closes.
        next.load(URLRequest(url: origin.appendingPathComponent("pending")))
        try await Task.sleep(for: .milliseconds(200))
        first?.close(); second?.close(); try await settled { closedA && closedB }
        let loadedState = try sessions.load(for: a.id)
        let state = try #require(loadedState)
        #expect(state.urls == [one.absoluteString, updated.absoluteString, "about:blank"])
        #expect(state.selectedIndex == 1)
        #expect(try sessions.load(for: b.id)?.urls == [three.absoluteString])
        first = nil; second = nil
        var rename = try #require(profiles.profile(withID: a.id)); rename.name = "Renamed own restore"
        let renamed = try profiles.upsert(rename)
        closedA = false
        first = try browser(renamed, paths, onClose: { closedA = true }); first?.show()
        try await loaded(try #require(first?.webView), updated)
        #expect(first?.tabCount == 3 && first?.selectedTabIndex == 1)
        #expect(try await first?.webView.evaluateJavaScript("localStorage.getItem('owned-session-marker')") as? String == "A")
        first?.close(); try await settled { closedA }; first = nil
        let clone = try profiles.duplicateProfile(try #require(profiles.profile(withID: a.id)), name: "Own restore clone")
        #expect(try sessions.load(for: clone.id) == nil)
        closedA = false
        first = try browser(clone, paths, onClose: { closedA = true }); first?.show()
        try await loaded(try #require(first?.webView), one)
        #expect(first?.tabCount == 1 && first?.selectedTabIndex == 0)
        #expect(try await first?.webView.evaluateJavaScript("localStorage.getItem('owned-session-marker')") as? String == nil)
        first?.close(); try await settled { closedA }; first = nil
        return [a.id, b.id, clone.id]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_SESSION_LIVE"] == "1"))
    func actualSaveFailureHoldsGuardsAndRetrySettlesBeforeRelease() async throws {
        let ids = try await failureScenario(); try await remove(ids)
    }
    private func failureScenario() async throws -> [UUID] {
        _ = NSApplication.shared
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory), profiles = ProfileStore(paths: paths)
        let profile = try profiles.upsert(BrowserProfile(name: "Own retry", startURL: "about:blank", startupMode: .restoreSession, engine: .webkit))
        var sessions = WebKitSessionStore(paths: paths); let failure = OwnedSessionWriteSwitch()
        sessions.beforeCommit = { try failure.check() }
        var closed = false, errors = 0
        var owned: WebKitProfileBrowser? = try browser(profile, paths, store: sessions, onError: { errors += 1 }, onClose: { closed = true })
        defer { owned?.close() }
        owned?.show(); try await loaded(try #require(owned?.webView), URL(string: "about:blank")!, blank: true)
        owned?.close(); try await settled { owned?.sessionWriteFailed == true }
        #expect(!closed && errors == 1)
        #expect(throws: ProfileProcessBusyError.self) { try paths.acquireWebKitSessionGuard(for: profile.id) }
        failure.allow(); owned?.close(); try await settled { closed }
        #expect(try WebKitSessionStore(paths: paths).load(for: profile.id)?.urls == ["about:blank"])
        let lease = try paths.acquireWebKitSessionGuard(for: profile.id); lease.release()
        owned = nil
        return [profile.id]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_SESSION_LIVE"] == "1"))
    func managerQuitDrainSavesWithoutDownloadsAndStartPageDoesNotCreateSession() async throws {
        #if DEBUG
        let ids = try await drainScenario(); try await remove(ids)
        #else
        throw WebKitProfileError.unsupported("Owned native manager observation requires DEBUG test build")
        #endif
    }
    #if DEBUG
    private func drainScenario() async throws -> [UUID] {
        _ = NSApplication.shared
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory), profiles = ProfileStore(paths: paths), manager = BrowserProcessManager(paths: paths)
        let origin = try base(), one = origin.appendingPathComponent("one")
        let enabled = try profiles.upsert(BrowserProfile(name: "Own drain enabled", startURL: one.absoluteString, startupMode: .restoreSession, engine: .webkit))
        let off = try profiles.upsert(BrowserProfile(name: "Own drain default", startURL: "about:blank", engine: .webkit))
        try manager.launchWebKitProfile(enabled); try manager.launchWebKitProfile(off)
        try await loaded(try #require(manager.webKitBrowserForTesting(profileID: enabled.id)?.webView), one)
        #expect(manager.hasOpenWebKitProfiles && !manager.hasActiveWebKitDownloads)
        #expect(await manager.drainWebKitForQuit())
        #expect(!manager.hasOpenWebKitProfiles && manager.processState(for: enabled.id) == .stopped)
        let sessions = WebKitSessionStore(paths: paths)
        #expect(try sessions.load(for: enabled.id)?.urls == [one.absoluteString])
        #expect(try sessions.load(for: off.id) == nil)
        return [enabled.id, off.id]
    }
    #endif
}
