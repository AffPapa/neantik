import AppKit
import Foundation
import Testing
import WebKit
@testable import NeAntik

@Suite(.serialized) @MainActor struct WebKitCacheLiveTests {
    private func origin() throws -> URL {
        let text = try #require(ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_CACHE_FIXTURE_URL"])
        let url = try #require(URL(string: text))
        guard url.scheme == "http", url.host == "127.0.0.1", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw WebKitProfileError.unsupported("Owned cache fixture must use loopback")
        }
        return url
    }
    private func loaded(_ browser: WebKitProfileBrowser) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if !browser.webView.isLoading,
               (try? await browser.webView.evaluateJavaScript("window.neantikOwnCacheFixture === true")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebKitProfileError.unsupported("Own headed cache page failed to load")
    }
    private func result(_ browser: WebKitProfileBrowser, _ script: String) async throws -> Any? {
        try await browser.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
    private func cached(_ browser: WebKitProfileBrowser) async throws -> String {
        let value = try await result(browser, "return await (await fetch('/cache-value', {cache:'force-cache'})).text()")
        return try #require(value as? String)
    }
    private func seed(_ browser: WebKitProfileBrowser, marker: String) async throws {
        let script = """
        document.cookie='owned-cache-marker=\(marker); Path=/; Max-Age=3600; SameSite=Lax';
        localStorage.setItem('owned-cache-marker','\(marker)');
        await new Promise((resolve,reject)=>{const q=indexedDB.open('owned-cache-db',1);q.onupgradeneeded=()=>q.result.createObjectStore('items');q.onerror=()=>reject(new Error('open'));q.onsuccess=()=>{const db=q.result;const t=db.transaction('items','readwrite');t.objectStore('items').put('\(marker)','marker');t.oncomplete=()=>{db.close();resolve()};t.onerror=()=>reject(new Error('put'))}});
        await navigator.serviceWorker.register('/worker.js'); await navigator.serviceWorker.ready;
        const cache=await caches.open('owned-application-cache');await cache.put('/owned-offline',new Response('\(marker)'));
        return true;
        """
        #expect(try await result(browser, script) as? Bool == true)
    }
    private func witness(_ browser: WebKitProfileBrowser) async throws -> [String: Any] {
        let script = """
        const idb=await new Promise((resolve,reject)=>{const q=indexedDB.open('owned-cache-db',1);q.onerror=()=>reject(new Error('open'));q.onsuccess=()=>{const db=q.result;const t=db.transaction('items','readonly');const r=t.objectStore('items').get('marker');r.onsuccess=()=>resolve(r.result??null);r.onerror=()=>reject(new Error('get'));t.oncomplete=()=>db.close()}});
        const cached=await caches.match('/owned-offline');
        return {cookie:document.cookie,local:localStorage.getItem('owned-cache-marker'),idb,worker:(await navigator.serviceWorker.getRegistrations()).length,offline:cached?await cached.text():null};
        """
        return try #require(try await result(browser, script) as? [String: Any])
    }
    private func intact(_ value: [String: Any], marker: String) -> Bool {
        (value["cookie"] as? String)?.contains("owned-cache-marker=\(marker)") == true &&
        value["local"] as? String == marker && value["idb"] as? String == marker &&
        (value["worker"] as? NSNumber)?.intValue == 1 && value["offline"] as? String == marker
    }
    private func close(_ manager: BrowserProcessManager) async throws {
        let drained = await manager.drainWebKitForQuit()
        try #require(drained)
    }
    private func controller(_ origin: URL, _ route: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: origin.appendingPathComponent(route))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WebKitProfileError.unsupported("Own fixture control failed") }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func ownedRunRoot() throws -> URL {
        let text = try #require(ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_CACHE_OWNED_RUN_ROOT"])
        let root = URL(fileURLWithPath: text).resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().resolvingSymlinksInPath().path == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path,
              root.lastPathComponent.hasPrefix("neantik-cache-native-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst("neantik-cache-native-".count))) != nil else {
            throw WebKitProfileError.unsupported("Invalid owned native run root")
        }
        return root
    }
    private func recordOwnedStores(_ ids: [UUID]) throws {
        let root = try ownedRunRoot()
        try AppPaths(rootDirectory: root).writePrivateFile(try JSONEncoder().encode(ids), to: root.appendingPathComponent("owned-stores.json"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_CACHE_LIVE"] == "1"))
    func actualClosedCacheAChangesBytesWhileBAndPersistentDataRemain() async throws {
        _ = try await scenario()
        // Store-container disposal runs in a NEW process with the same test
        // executable, after this one's WebKit network connections terminate.
        // A window close alone does not establish store-container deletion authority.
    }
    private func scenario() async throws -> [UUID] {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-cache-native-owned-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths), origin = try origin()
        let a = try store.upsert(BrowserProfile(name: "Owned cache A", startURL: origin.appendingPathComponent("page").absoluteString, startupMode: .restoreSession, engine: .webkit))
        let b = try store.upsert(BrowserProfile(name: "Owned cache B", startURL: a.startURL, startupMode: .restoreSession, engine: .webkit))
        try recordOwnedStores([a.id, b.id])
        let manager = BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent }, validatesPersistedProfiles: true)
        defer { manager.closeWebKitWindows() }
        try manager.launchWebKitProfile(a); try manager.launchWebKitProfile(b)
        var first = manager.webKitBrowserForTesting(profileID: a.id)
        var second = manager.webKitBrowserForTesting(profileID: b.id)
        try await loaded(try #require(first)); try await loaded(try #require(second))
        try await seed(try #require(first), marker: "A"); try await seed(try #require(second), marker: "B")
        #expect(intact(try await witness(try #require(first)), marker: "A"))
        #expect(intact(try await witness(try #require(second)), marker: "B"))
        var incorrectlyDispatched = false
        await #expect(throws: BrowserProfileDeletionBlockedError.self) {
            try await manager.clearWebKitCache(profile: a) { _ in incorrectlyDispatched = true }
        }
        #expect(!incorrectlyDispatched)
        #expect(try await cached(try #require(first)) == "owned-cache-v1")
        #expect(try await cached(try #require(second)) == "owned-cache-v1")
        let counts = try await controller(origin, "advance")
        #expect((counts["cacheHits"] as? NSNumber)?.intValue == 2)
        // Native positive cache-hit control: origin is already v2; both browser
        // stores must still return v1 before we remove anything.
        #expect(try await cached(try #require(first)) == "owned-cache-v1")
        #expect(try await cached(try #require(second)) == "owned-cache-v1")
        let cachedCounts = try await controller(origin, "counts")
        #expect((cachedCounts["cacheHits"] as? NSNumber)?.intValue == 2)
        _ = first?.openTab(at: origin.appendingPathComponent("second"))
        try await loaded(try #require(first))
        try await close(manager); first = nil; second = nil
        let sidecar = root.appendingPathComponent("WebKitSessions/\(a.id.uuidString.lowercased()).json")
        let priorSession = try Data(contentsOf: sidecar), priorMetadata = try Data(contentsOf: paths.profilesFile)
        try await manager.clearWebKitCache(profile: a)
        #expect(try Data(contentsOf: sidecar) == priorSession)
        #expect(try Data(contentsOf: paths.profilesFile) == priorMetadata)
        try manager.launchWebKitProfile(a); try manager.launchWebKitProfile(b)
        first = manager.webKitBrowserForTesting(profileID: a.id); second = manager.webKitBrowserForTesting(profileID: b.id)
        try await loaded(try #require(first)); try await loaded(try #require(second))
        #expect(first?.tabCount == 2 && first?.selectedTabIndex == 1)
        #expect(intact(try await witness(try #require(first)), marker: "A"))
        #expect(intact(try await witness(try #require(second)), marker: "B"))
        #expect(try await cached(try #require(first)) == "owned-cache-v2")
        #expect(try await cached(try #require(second)) == "owned-cache-v1")
        let finalCounts = try await controller(origin, "counts")
        #expect((finalCounts["cacheHits"] as? NSNumber)?.intValue == 3)
        // Wrong-type negative control on our disposable A store: this very same
        // witness must reject a backend that clears cookies accidentally.
        await WKWebsiteDataStore(forIdentifier: a.id).removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
        #expect(!intact(try await witness(try #require(first)), marker: "A"))
        #expect(intact(try await witness(try #require(second)), marker: "B"))
        // Remove only our test registrations after the completed preservation
        // and wrong-type controls; no production data is part of disposal.
        _ = try await result(try #require(first), "return await Promise.all((await navigator.serviceWorker.getRegistrations()).map(r=>r.unregister()))")
        _ = try await result(try #require(second), "return await Promise.all((await navigator.serviceWorker.getRegistrations()).map(r=>r.unregister()))")
        try await close(manager); first = nil; second = nil
        return [a.id,b.id]
    }
}

@Suite(.serialized) @MainActor struct WebKitCacheOwnedCleanupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_CACHE_CLEANUP"] == "1"))
    func removeOnlyRecordedSyntheticStoresAfterOriginalProcessExited() async throws {
        let text = try #require(ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_CACHE_OWNED_RUN_ROOT"])
        let root = URL(fileURLWithPath: text).resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().resolvingSymlinksInPath().path == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path, root.lastPathComponent.hasPrefix("neantik-cache-native-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst("neantik-cache-native-".count))) != nil else { throw WebKitProfileError.unsupported("Invalid owned cleanup root") }
        let path = root.appendingPathComponent("owned-stores.json")
        let identity = try #require(try AppPaths(rootDirectory: root).privateFileEntryIdentity(path))
        guard identity.size <= 1024 else { throw WebKitProfileError.unsupported("Oversize own cleanup receipt") }
        let ids = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: path))
        try #require(ids.count == 2 && Set(ids).count == 2)
        _ = NSApplication.shared
        // Initialize WebKit with an ephemeral store. Calling removal before
        // any store initialization crashes this macOS SDK in a fresh process.
        // Never initialize the default or recorded persistent stores here.
        let initialization = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(initialization) {} }
        for id in ids {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var error: Error?
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                error = await withCheckedContinuation { continuation in
                    WKWebsiteDataStore.remove(forIdentifier: id) { continuation.resume(returning: $0) }
                }
            } while error != nil && ContinuousClock.now < deadline
            #expect(error == nil, "Own store-container disposal must actually succeed in fresh process")
        }
    }
}
