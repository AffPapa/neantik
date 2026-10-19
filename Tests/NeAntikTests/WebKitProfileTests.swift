import AppKit
import Foundation
import Testing
import WebKit
@testable import NeAntik

@MainActor
private final class WebKitPopupCounter: NSObject, WKUIDelegate {
    var attempts = 0
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        attempts += 1
        return nil // Observe the request without creating another context.
    }
}

@MainActor
@Suite(.serialized)
struct WebKitProfileTests {
    private func encoder() -> JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }

    @Test func windowCommandsHandleCapsLockAndCyrillicWithoutCapturingPlainInput() {
        #expect(WebKitWindowCommand.resolve(characters: "l", keyCode: 37, modifiers: [.command, .capsLock]) == .address)
        #expect(WebKitWindowCommand.resolve(characters: "д", keyCode: 37, modifiers: .command) == .address)
        #expect(WebKitWindowCommand.resolve(characters: "к", keyCode: 15, modifiers: .command) == .reload)
        #expect(WebKitWindowCommand.resolve(characters: "l", keyCode: 37, modifiers: []) == nil)
        #expect(WebKitWindowCommand.resolve(characters: "l", keyCode: 37, modifiers: [.command, .option]) == nil)
        #expect(WebKitWindowCommand.resolve(characters: "x", keyCode: 7, modifiers: .command) == nil)
        #expect(WebKitWindowCommand.resolve(characters: "t", keyCode: 17, modifiers: .command) == .newTab)
        #expect(WebKitWindowCommand.resolve(characters: "е", keyCode: 17, modifiers: .command) == .newTab)
        #expect(WebKitWindowCommand.resolve(characters: "]", keyCode: 30, modifiers: [.command, .shift]) == .nextTab)
        #expect(WebKitWindowCommand.resolve(characters: "[", keyCode: 33, modifiers: [.command, .shift]) == .previousTab)
        #expect(WebKitWindowCommand.resolve(characters: "t", keyCode: 17, modifiers: [.command, .shift]) == nil)
        #expect(WebKitWindowCommand.resolve(characters: "t", keyCode: 17, modifiers: []) == nil)
    }

    @Test func tabClosurePreservesBackgroundSelectionAndChoosesAdjacentTab() {
        let a = UUID(), b = UUID(), c = UUID(), unknown = UUID()
        var order = WebKitTabOrder(first: a)
        order.append(b); order.append(c); order.select(b)
        #expect(!order.select(unknown) && order.selected == b)
        #expect(!order.remove(unknown) && order.ids == [a, b, c])
        #expect(order.remove(a) && order.selected == b)
        order.append(b) // A duplicate must not change selection or order.
        #expect(order.ids == [b, c] && order.selected == b)
        #expect(order.remove(b) && order.selected == c)
        #expect(!order.remove(c) && order.ids == [c])
        order.append(a); order.append(b)
        order.cycle(1); #expect(order.selected == c)
        order.cycle(-1); #expect(order.selected == b)
        #expect(order.remove(b) && order.selected == a)
    }

    @Test func popupOwnershipRejectsForeignDefaultAndEphemeralStores() {
        let a = UUID(), b = UUID(), url = URL(string: "https://example.com/")!
        #expect(WebKitProfilePolicy.permitsPopup(profileID: a, openerIsOwned: true, storeID: a, persistent: true, url: url))
        #expect(!WebKitProfilePolicy.permitsPopup(profileID: a, openerIsOwned: false, storeID: a, persistent: true, url: url))
        #expect(!WebKitProfilePolicy.permitsPopup(profileID: a, openerIsOwned: true, storeID: b, persistent: true, url: url))
        #expect(!WebKitProfilePolicy.permitsPopup(profileID: a, openerIsOwned: true, storeID: nil, persistent: true, url: url))
        #expect(!WebKitProfilePolicy.permitsPopup(profileID: a, openerIsOwned: true, storeID: a, persistent: false, url: url))
        #expect(!WebKitProfilePolicy.permitsPopup(profileID: a, openerIsOwned: true, storeID: a, persistent: true, url: URL(string: "file:///fixture")))
        #expect(WebKitProfilePolicy.canOpenTab(count: 1))
        #expect(WebKitProfilePolicy.canOpenTab(count: 31))
        #expect(!WebKitProfilePolicy.canOpenTab(count: 32))
        #expect(!WebKitProfilePolicy.canOpenTab(count: -1))
    }

    @Test func legacyProfilesStayChromiumAndUnknownEngineIsRejected() throws {
        let data = try encoder().encode(BrowserProfile(name: "Legacy"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "engine")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.engine == .chromium)
        object["engine"] = "unknown-engine"
        #expect(throws: (any Error).self) { try decoder.decode(BrowserProfile.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func webKitRoundTripCloneAndConfigurationRetainEngine() throws {
        let profile = BrowserProfile(name: "WebKit", startURL: "about:blank", engine: .webkit)
        let bytes = try ProfileStore.encodeProfiles([profile], encoder: encoder())
        #expect(try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])["schemaVersion"] as? Int == 2)
        #expect(try ProfileStore.decodeProfiles(bytes).first?.engine == .webkit)
        let clone = profile.duplicated()
        #expect(clone.engine == .webkit && clone.id != profile.id)
        let document = try ProfileConfigurationTransferDocument(profiles: [profile])
        #expect(document.schemaVersion == 2)
        #expect(try document.makeProfiles().first?.engine == .webkit)
        #expect(try document.makeProfiles().first?.id != profile.id)
        #expect(try ProfileStore.encodeProfiles([BrowserProfile(name: "Chrome")], encoder: encoder()).first == 91)
    }

    @Test func webKitCannotBeDisguisedAsLegacyMetadataOrConfiguration() throws {
        let profile = BrowserProfile(name: "WebKit", startURL: "about:blank", engine: .webkit)
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(encoder().encode([profile])) }
        var envelope = try #require(JSONSerialization.jsonObject(with: ProfileStore.encodeProfiles([profile], encoder: encoder())) as? [String: Any])
        envelope["schemaVersion"] = 1
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(JSONSerialization.data(withJSONObject: envelope)) }
        let document = try ProfileConfigurationTransferDocument(profiles: [profile])
        var configuration = try #require(JSONSerialization.jsonObject(with: encoder().encode(document)) as? [String: Any])
        configuration["schemaVersion"] = 1
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(throws: (any Error).self) { try decoder.decode(ProfileConfigurationTransferDocument.self, from: JSONSerialization.data(withJSONObject: configuration)) }
    }

    @Test func webKitTemplatesUseVersionedLibraryAndKeepEngineThroughMCP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-webkit-template-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let profile = try store.upsert(BrowserProfile(name: "WebKit template", startURL: "about:blank", engine: .webkit))
        let template = try UserProfileTemplate(name: "WebKit saved", profile: profile, folderID: nil)
        var legacy = ManagerLibraryDocument(); legacy.templates = [template]
        #expect(throws: (any Error).self) { try legacy.validate() }
        let library = try await ManagerLibraryRepository(paths: paths).update { $0.templates.append(template) }
        #expect(library.schemaVersion == 2)
        let reloaded = try await ManagerLibraryRepository(paths: paths).load()
        #expect(reloaded.templates.first?.makeProfile().engine == .webkit)
        let engine = MCPProfileManagement(root: root, allowsManagement: true)
        let listed = try await engine.call("template_list", [:])
        let created = try await engine.call("profile_create", ["name": "From WebKit", "templateID": template.id.uuidString, "expectedOrganizationRevision": listed["organizationRevision"]!])
        #expect(created["engine"] as? String == "webkit" && created["id"] as? String != profile.id.uuidString)
    }

    @Test func engineCannotBeChangedByMetadataEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-webkit-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(paths: AppPaths(rootDirectory: root))
        let saved = try store.upsert(BrowserProfile(name: "Engine", engine: .webkit))
        var changed = saved; changed.engine = .chromium
        #expect(throws: (any Error).self) { try store.upsert(changed) }
        #expect(store.profile(withID: saved.id)?.engine == .webkit)
        changed = saved; changed.name = "Renamed"
        #expect(try store.upsert(changed).engine == .webkit)
    }

    @Test func webKitProxyMetadataIsPreservedButLaunchFailsClosed() throws {
        var profile = BrowserProfile(name: "Boundary", startURL: "about:blank", engine: .webkit)
        try WebKitProfilePolicy.validate(profile)
        profile.proxy = ProxyConfiguration(kind: .socks5, host: "127.0.0.1", port: 1, username: "synthetic")
        try WebKitProfilePolicy.validateConfiguration(profile)
        #expect(throws: WebKitProfileError.self) { try WebKitProfilePolicy.validate(profile) }
        let store = ProfileStore(paths: AppPaths(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-webkit-proxy-metadata-" + UUID().uuidString)))
        defer { try? FileManager.default.removeItem(at: store.paths.rootDirectory) }
        let saved = try store.upsert(profile)
        #expect(saved.proxy == profile.proxy)
        #expect(throws: WebKitProfileError.self) { try WebKitProfilePolicy.validate(saved) }
        profile.proxy?.port = 0
        #expect(throws: (any Error).self) { try WebKitProfilePolicy.validate(profile) }
        profile.proxy = nil; profile.startupMode = .restoreSession
        try WebKitProfilePolicy.validate(profile)
        #expect(!WebKitProfilePolicy.permits(URL(string: "file:///fixture")!))
        #expect(!WebKitProfilePolicy.permits(URL(string: "javascript:alert(1)")!))
        #expect(WebKitProfilePolicy.permits(URL(string: "https://example.com/")!))
    }

    @Test func unsupportedWebKitContextBlocksLaunchWithoutInvalidatingStoredMetadata() throws {
        for identity in [BrowserIdentity(timezoneIdentifier: "Europe/London"), BrowserIdentity(localeIdentifier: "en-GB")] {
            let profile = BrowserProfile(name: "Owned unsupported context", startURL: "about:blank", engine: .webkit, identity: identity)
            try WebKitProfilePolicy.validateConfiguration(profile)
            #expect(throws: WebKitProfileError.self) { try WebKitProfilePolicy.validate(profile) }
            let bytes = try ProfileStore.encodeProfiles([profile], encoder: encoder())
            #expect(try ProfileStore.decodeProfiles(bytes).first?.identity == identity)
        }
        try WebKitProfilePolicy.validate(BrowserProfile(name: "System settings", startURL: "about:blank", engine: .webkit))
    }

    @Test func lifetimeGuardBlocksAnotherManagerAndMaintenanceWithoutWaiting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-webkit-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), id = UUID()
        let lease = try paths.acquireWebKitSessionGuard(for: id)
        #expect(throws: ProfileProcessBusyError.self) { try paths.acquireWebKitSessionGuard(for: id) }
        #expect(throws: ProfileProcessBusyError.self) { try paths.withProcessLockGuard(for: id) {} }
        lease.release()
        try paths.withProcessLockGuard(for: id) {}
    }

    @Test func webKitMetadataFenceBlocksForeignWriterButAllowsLaunchBookkeeping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-webkit-writer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let saved = try store.upsert(BrowserProfile(name: "Fixture", engine: .webkit))
        let lease = try paths.acquireWebKitMetadataGuard(for: saved.id)
        defer { lease.release() }
        var renamed = saved; renamed.name = "Foreign edit"
        #expect(throws: ProfileProcessBusyError.self) { try ProfileStore(paths: paths).upsert(renamed) }
        #expect(store.markLaunched(saved.id))
        #expect(store.profile(withID: saved.id)?.name == "Fixture")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_LIVE"] == "1"))
    func persistentCookieStoresAreSeparateAndSameIdentifierIsPositiveControl() async throws {
        let ids = try await cookieScenario()
        try await remove(ids.0); try await remove(ids.1)
    }

    private func cookieScenario() async throws -> (UUID, UUID) {
        let a = UUID(), b = UUID()
        let first = autoreleasepool { WKWebsiteDataStore(forIdentifier: a) }
        let second = autoreleasepool { WKWebsiteDataStore(forIdentifier: b) }
        let cookie = try #require(HTTPCookie(properties: [.domain: "neantik-fixture.invalid", .path: "/", .name: "fixture", .value: UUID().uuidString, .expires: Date().addingTimeInterval(3600)]))
        await withCheckedContinuation { continuation in first.httpCookieStore.setCookie(cookie) { continuation.resume() } }
        let aCookies = await cookies(first), bCookies = await cookies(second), sameCookies = await cookies(WKWebsiteDataStore(forIdentifier: a))
        #expect(aCookies.contains { $0.name == "fixture" && $0.value == cookie.value })
        #expect(!bCookies.contains { $0.name == "fixture" })
        #expect(sameCookies.contains { $0.name == "fixture" && $0.value == cookie.value })
        return (a, b)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_LIVE"] == "1"))
    func headedOwnWindowsIsolateStorageAndRetainItAfterClose() async throws {
        let ids = try await headedScenario()
        try await remove(ids.0); try await remove(ids.1)
    }

    private func headedScenario() async throws -> (UUID, UUID) {
        let fixture = try #require(ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_FIXTURE_URL"])
        let url = try #require(URL(string: fixture))
        #expect(url.scheme == "http" && url.host == "127.0.0.1" && url.path == "/fixture")
        guard url.scheme == "http", url.host == "127.0.0.1", url.path == "/fixture", url.user == nil, url.password == nil else { throw NeAntikError.invalidProfile }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-webkit-headed-" + UUID().uuidString)
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let a = try store.upsert(BrowserProfile(name: "WebKit QA A", startURL: fixture, engine: .webkit))
        let b = try store.upsert(BrowserProfile(name: "WebKit QA B", startURL: fixture, engine: .webkit))
        var first: WebKitProfileBrowser? = try browser(a, paths: paths)
        var second: WebKitProfileBrowser? = try browser(b, paths: paths)
        defer { first?.close(); second?.close(); try? FileManager.default.removeItem(at: root) }
        first?.show(); second?.show()
        try await loaded(try #require(first?.webView), url: url)
        try await loaded(try #require(second?.webView), url: url)
        let firstValue = UUID().uuidString, secondValue = UUID().uuidString
        do {
        let firstView = try #require(first?.webView), secondView = try #require(second?.webView)
        #expect(try await firstView.evaluateJavaScript("window.neantikAutomaticPopupAttempted") as? Bool == true)
        #expect(try await firstView.evaluateJavaScript("window.neantikAutomaticPopupOpened") as? Bool == false)
        #expect(first?.tabCount == 1 && second?.tabCount == 1)
        // Negative control: without protection the same real page requests a
        // popup. Merely returning an empty result would not pass this observer.
        let counter = WebKitPopupCounter()
        let popupConfig = WKWebViewConfiguration()
        popupConfig.websiteDataStore = WKWebsiteDataStore(forIdentifier: a.id)
        popupConfig.preferences.javaScriptCanOpenWindowsAutomatically = true
        let popupControl = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 420), configuration: popupConfig)
        popupControl.uiDelegate = counter
        let controlWindow = NSWindow(contentRect: popupControl.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        controlWindow.isReleasedWhenClosed = false
        defer { popupControl.stopLoading(); popupControl.uiDelegate = nil; controlWindow.contentView = nil; controlWindow.close() }
        controlWindow.title = "Own WebKit popup negative control"
        controlWindow.contentView = popupControl; controlWindow.makeKeyAndOrderFront(nil)
        popupControl.load(URLRequest(url: url)); try await loaded(popupControl, url: url)
        #expect(counter.attempts > 0)
        popupControl.stopLoading(); popupControl.uiDelegate = nil; controlWindow.contentView = nil; controlWindow.close()
        #expect(try await storage(secondView, value: nil)["local"] as? String == nil)
        _ = try await storage(firstView, value: firstValue)
        let emptyB = try await storage(secondView, value: nil)
        #expect(emptyB["local"] as? String == nil && emptyB["idb"] as? String == nil)
        #expect(!(emptyB["cookie"] as? String ?? "").contains(firstValue))
        _ = try await storage(secondView, value: secondValue)
        let readA = try await storage(firstView, value: nil)
        #expect(readA["local"] as? String == firstValue && readA["idb"] as? String == firstValue)
        #expect((readA["cookie"] as? String ?? "").contains(firstValue))
        let initialTab = try #require(first?.selectedTabID)
        let previousPressure = ManagerLaunchAdmission.shared.pressured
        ManagerLaunchAdmission.shared.setPressureForTesting(true)
        #expect(first?.openTab(at: url) == nil && first?.tabCount == 1)
        ManagerLaunchAdmission.shared.setPressureForTesting(previousPressure)
        let ownTab = try #require(first?.openTab(at: url))
        #expect(!ownTab.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        try await loaded(ownTab, url: url)
        let sameProfile = try await storage(ownTab, value: nil)
        #expect(sameProfile["local"] as? String == firstValue && sameProfile["idb"] as? String == firstValue)
        #expect((sameProfile["cookie"] as? String ?? "").contains(firstValue))
        #expect(first?.tabCount == 2)
        #expect(first?.openTab(at: URL(string: "file:///fixture")!) == nil && first?.tabCount == 2)
        let secondTab = try #require(first?.selectedTabID)
        first?.selectTab(initialTab)
        #expect(first?.webView === firstView)
        first?.closeTab(secondTab)
        #expect(first?.tabCount == 1 && first?.selectedTabID == initialTab)
        #expect(try await storage(secondView, value: nil)["local"] as? String == secondValue)
        // Negative control for the observer: deliberately sharing A's store
        // must expose A's value. A test that merely always returns null fails.
        let config = WKWebViewConfiguration(); config.websiteDataStore = WKWebsiteDataStore(forIdentifier: a.id)
        var shared: WKWebView? = WKWebView(frame: .zero, configuration: config)
        shared?.load(URLRequest(url: url))
        try await loaded(try #require(shared), url: url)
        #expect(try await storage(try #require(shared), value: nil)["local"] as? String == firstValue)
        shared?.stopLoading(); shared = nil
        #expect(throws: (any Error).self) { try paths.acquireWebKitSessionGuard(for: a.id) }
        var edited = a; edited.name = "Blocked while active"
        #expect(throws: (any Error).self) { try store.upsert(edited) }
        }
        first?.close(); first = nil
        var edited = a
        edited.name = "WebKit QA renamed"
        let renamed = try store.upsert(edited)
        first = try browser(renamed, paths: paths); first?.show()
        try await loaded(try #require(first?.webView), url: url)
        let reopened = try await storage(try #require(first?.webView), value: nil)
        #expect(reopened["local"] as? String == firstValue && reopened["idb"] as? String == firstValue)
        first?.close(); first = nil; second?.close(); second = nil
        return (a.id, b.id)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_LIVE"] == "1"))
    func managerReconciliationKeepsOwnWebKitWindowManaged() async throws {
        let id = try await managerScenario()
        try await remove(id)
    }

    private func managerScenario() async throws -> UUID {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-webkit-manager-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths), manager = BrowserProcessManager(paths: paths)
        let profile = try store.upsert(BrowserProfile(name: "WebKit lifecycle QA", startURL: "about:blank", engine: .webkit))
        try manager.launchWebKitProfile(profile)
        defer { manager.stop(profileID: profile.id) }
        #expect(store.markLaunched(profile.id))
        manager.reconcile(profiles: store.profiles)
        try await Task.sleep(for: .milliseconds(600))
        #expect(manager.processState(for: profile.id) == .managed)
        #expect(manager.runningProfileIDs.contains(profile.id))
        #expect(manager.lastError == nil)
        #expect(throws: (any Error).self) { try manager.launchWebKitProfile(profile) }
        manager.stop(profileID: profile.id)
        #expect(manager.processState(for: profile.id) == .stopped)
        try manager.launchWebKitProfile(try #require(store.profile(withID: profile.id)))
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApplication.shared)
        #expect(manager.processState(for: profile.id) == .stopped)
        try paths.withProcessLockGuard(for: profile.id) {}
        return profile.id
    }

    private func browser(_ profile: BrowserProfile, paths: AppPaths) throws -> WebKitProfileBrowser {
        let lease = try paths.acquireWebKitSessionGuard(for: profile.id)
        let metadataLease = try paths.acquireWebKitMetadataGuard(for: profile.id)
        return try autoreleasepool { try WebKitProfileBrowser(profile: profile, lease: lease, metadataLease: metadataLease, onClose: {}) }
    }
    private func loaded(_ view: WKWebView, url: URL) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if view.url == url, !view.isLoading,
               (try? await view.evaluateJavaScript("window.neantikOwnFixture === true")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebKitProfileError.unsupported("Own WebKit fixture did not load within 15 seconds")
    }
    private func storage(_ view: WKWebView, value: String?) async throws -> [String: Any] {
        let script = """
        if (window.neantikOwnFixture !== true) throw new Error('wrong fixture');
        const db = await new Promise((ok, fail) => {
          const req = indexedDB.open('neantik-own-fixture', 1);
          req.onupgradeneeded = () => req.result.createObjectStore('values');
          req.onsuccess = () => ok(req.result); req.onerror = () => fail(req.error);
        });
        try {
          if (value !== null) {
            localStorage.setItem('fixture', value);
            document.cookie = 'fixture=' + value + '; Path=/; Max-Age=3600; SameSite=Lax';
            await new Promise((ok, fail) => {
              const tx = db.transaction('values', 'readwrite'); tx.objectStore('values').put(value, 'fixture');
              tx.oncomplete = ok; tx.onerror = () => fail(tx.error); tx.onabort = () => fail(tx.error);
            });
          }
          const result = await new Promise((ok, fail) => {
            const req = db.transaction('values').objectStore('values').get('fixture');
            req.onsuccess = () => ok(req.result ?? null); req.onerror = () => fail(req.error);
          });
          return { local: localStorage.getItem('fixture'), idb: result, cookie: document.cookie };
        } finally { db.close(); }
        """
        return try #require(try await view.callAsyncJavaScript(script, arguments: ["value": value as Any? ?? NSNull()], in: nil, contentWorld: .page) as? [String: Any])
    }

    private func cookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
    }
    private func remove(_ id: UUID) async throws {
        // Only remove after the scenario has returned and all view/store owners
        // are gone. A closed window alone is not a released WebKit session.
        try await Task.sleep(for: .milliseconds(200))
        let error: Error? = await withCheckedContinuation { continuation in WKWebsiteDataStore.remove(forIdentifier: id) { error in continuation.resume(returning: error) } }
        if let error {
            let reason = (error as NSError).localizedDescription
            let category = reason.contains("by network process") ? "network-process-in-use" : reason.contains("in use") ? "pages-in-use" : reason.contains("delete files") ? "disk-removal" : "other"
            Issue.record("Synthetic WebKit store removal failed: \(category)")
        }
        let ids: [UUID] = await withCheckedContinuation { continuation in WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) } }
        #expect(!ids.contains(id))
    }
}
