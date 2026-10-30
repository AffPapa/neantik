import AppKit
import Foundation
import Testing
import WebKit
@testable import NeAntik

/// Opt-in, headed evidence. Each phase runs in a fresh process; only UUIDs
/// created in the owned run root may be opened or removed. No default store.
@Suite(.serialized) @MainActor struct WebKitDeletionLiveTests {
    private struct Context {
        let root: URL
        let paths: AppPaths
        let origin: URL
        let store: ProfileStore
        let manager: BrowserProcessManager
    }
    private func context() throws -> Context {
        let environment = ProcessInfo.processInfo.environment
        let raw = try #require(environment["NEANTIK_WEBKIT_DELETE_ROOT"])
        let root = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().resolvingSymlinksInPath() == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath(),
              root.lastPathComponent.hasPrefix("neantik-delete-native-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst("neantik-delete-native-".count))) != nil else {
            throw WebKitProfileError.unsupported("Invalid owned deletion test root")
        }
        let originText = try #require(environment["NEANTIK_WEBKIT_DELETE_ORIGIN"])
        let url = try #require(URL(string: originText))
        guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw WebKitProfileError.unsupported("Invalid owned deletion loopback origin")
        }
        _ = NSApplication.shared
        let paths = AppPaths(rootDirectory: root.appendingPathComponent("Metadata"))
        let store = ProfileStore(paths: paths, trashDirectory: { source in
            let destination = root.appendingPathComponent("OwnedTrash-\(UUID())")
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        })
        // Production launch admission remains enabled. Resource refusals fail
        // this test; the runner's normal observation does not override them.
        let manager = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false },
            browserDataProcessInspector: { _ in .absent }, validatesPersistedProfiles: true)
        return Context(root: root, paths: paths, origin: url, store: store, manager: manager)
    }
    private func browser(_ context: Context, profile: BrowserProfile) async throws -> WebKitProfileBrowser {
        try context.manager.launchWebKitProfile(profile)
        let view = try #require(context.manager.webKitBrowserForTesting(profileID: profile.id))
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if !view.webView.isLoading,
               (try? await view.webView.evaluateJavaScript("window.neantikOwnCacheFixture === true")) as? Bool == true { return view }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebKitProfileDeletionError.interrupted
    }
    private func run(_ view: WebKitProfileBrowser, _ script: String) async throws -> Any? {
        try await view.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
    private func seed(_ view: WebKitProfileBrowser, marker: String) async throws {
        let value = try await run(view, """
        document.cookie='own-delete=\(marker); Path=/; Max-Age=3600; SameSite=Lax';
        localStorage.setItem('own-delete','\(marker)');
        await new Promise((resolve,reject)=>{const q=indexedDB.open('own-delete-db',1);q.onupgradeneeded=()=>q.result.createObjectStore('items');q.onerror=()=>reject(Error('open'));q.onsuccess=()=>{const db=q.result,t=db.transaction('items','readwrite');t.objectStore('items').put('\(marker)','marker');t.oncomplete=()=>{db.close();resolve()};t.onerror=()=>reject(Error('write'))}});
        await navigator.serviceWorker.register('/worker.js');await navigator.serviceWorker.ready;
        const c=await caches.open('own-delete-cache');await c.put('/own-delete-offline',new Response('\(marker)'));
        return true;
        """)
        #expect(value as? Bool == true)
    }
    private func witness(_ view: WebKitProfileBrowser, marker: String) async throws {
        let value = try await run(view, """
        const idb=await new Promise((resolve,reject)=>{const q=indexedDB.open('own-delete-db',1);q.onerror=()=>reject(Error('open'));q.onsuccess=()=>{const db=q.result,t=db.transaction('items','readonly'),r=t.objectStore('items').get('marker');r.onsuccess=()=>resolve(r.result??null);r.onerror=()=>reject(Error('read'));t.oncomplete=()=>db.close()}});
        const cache=await caches.match('/own-delete-offline');
        return {cookie:document.cookie,local:localStorage.getItem('own-delete'),idb,worker:(await navigator.serviceWorker.getRegistrations()).length,offline:cache?await cache.text():null};
        """)
        let actual = try #require(value as? [String: Any])
        #expect((actual["cookie"] as? String)?.contains("own-delete=\(marker)") == true)
        #expect(actual["local"] as? String == marker && actual["idb"] as? String == marker)
        #expect((actual["worker"] as? NSNumber)?.intValue == 1 && actual["offline"] as? String == marker)
    }
    private func ids(_ context: Context) throws -> [UUID] {
        let file = context.root.appendingPathComponent("owned-stores.json")
        let identity = try #require(try AppPaths(rootDirectory: context.root).privateFileEntryIdentity(file))
        guard identity.size <= 1024 else { throw WebKitProfileDeletionError.unsafeJournal }
        let ids = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: file))
        guard ids.count == 2, Set(ids).count == 2 else { throw WebKitProfileDeletionError.unsafeJournal }
        return ids
    }
    private func stores() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_DELETE_PHASE"] == "seed"))
    func seedTwoOwnedHeadedStoresAndRefuseLiveDeletion() async throws {
        let c = try context()
        defer { c.manager.closeWebKitWindows() }
        let a = try c.store.upsert(BrowserProfile(name: "Own deletion A", startURL: c.origin.appendingPathComponent("page").absoluteString, startupMode: .restoreSession, engine: .webkit))
        let b = try c.store.upsert(BrowserProfile(name: "Own preservation B", startURL: a.startURL, startupMode: .restoreSession, engine: .webkit))
        try AppPaths(rootDirectory: c.root).writePrivateFile(try JSONEncoder().encode([a.id,b.id]), to: c.root.appendingPathComponent("owned-stores.json"))
        let first = try await browser(c, profile: a), second = try await browser(c, profile: b)
        try await seed(first, marker: "A"); try await seed(second, marker: "B")
        try await witness(first, marker: "A"); try await witness(second, marker: "B")
        await #expect(throws: BrowserProfileDeletionBlockedError.self) {
            try await c.manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: c.store,
                operation: { _ in Issue.record("Live store cannot reach native deletion") }, afterCommit: { _ in })
        }
        #expect(try WebKitProfileDeletionJournal(paths: c.paths).load(for: a.id) == nil)
        _ = first.openTab(at: c.origin.appendingPathComponent("second"))
        let drained = await c.manager.drainWebKitForQuit()
        try #require(drained)
        #expect(try WebKitSessionStore(paths: c.paths).load(for: a.id)?.urls.count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_DELETE_PHASE"] == "delete"))
    func nativeUUIDRemovalPreservesOtherStoreAndSessionInFreshProcess() async throws {
        let c = try context(), own = try ids(c)
        defer { c.manager.closeWebKitWindows() }
        let a = try #require(c.store.profile(withID: own[0])), b = try #require(c.store.profile(withID: own[1]))
        let initialization = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(initialization) {} }
        let before = await stores()
        try #require(before.contains(a.id) && before.contains(b.id))
        let beforeSessionB = try WebKitSessionStore(paths: c.paths).load(for: b.id)
        // Uses the actual public UUID-removal backend, without an injected callback.
        var cleanup: [UUID] = []
        try await c.manager.deleteClosedWebKitProfile(profileID: a.id, expected: a, store: c.store,
            afterCommit: { cleanup.append($0) })
        let after = await stores()
        #expect(!after.contains(a.id) && after.contains(b.id))
        #expect(cleanup == [a.id] && c.store.profile(withID: a.id) == nil)
        #expect(try WebKitSessionStore(paths: c.paths).load(for: a.id) == nil)
        #expect(try WebKitSessionStore(paths: c.paths).load(for: b.id) == beforeSessionB)
        #expect(try WebKitProfileDeletionJournal(paths: c.paths).load(for: a.id)?.stage == .metadataRemoved)
        #expect(throws: BrowserProfileDeletedError.self) { try c.manager.launchWebKitProfile(a) }
        let second = try await browser(c, profile: b)
        try await witness(second, marker: "B")
        let drained = await c.manager.drainWebKitForQuit()
        try #require(drained)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_DELETE_PHASE"] == "cleanup"))
    func removeOnlyTwoRecordedSyntheticStoresAfterAllOwnerProcessesExit() async throws {
        let c = try context()
        for id in try ids(c) { try await WebKitDataStoreRemoval.remove(profileID: id) }
        let remaining = await stores()
        #expect(try ids(c).allSatisfy { !remaining.contains($0) })
    }
}
