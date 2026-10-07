import AppKit
import Foundation
import Testing
@testable import NeAntik

@MainActor
@Suite(.serialized)
struct LiveManagerStorageTests {
    @Test func exactRuntimeSyntheticStorageLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEANTIK_RUN_LIVE_STORAGE"] == "1",
              let app = environment["NEANTIK_LIVE_AUDIT_APP"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-storage-fixture-\(UUID())")
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let server = try await FingerprintAuditLoopbackServer.start()
        defer { server.stop() }
        let store = ProfileStore(paths: paths)
        let profile = try store.upsert(BrowserProfile(name: "Synthetic storage", startURL: server.url.absoluteString))
        let runtime = BrowserRuntime(name: "NeAntik Browser", executableURL: URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser"), source: "Exact runtime storage fixture", flavor: .fingerprintChromium)
        #expect(BrowserRuntimePreflightValidator.validate(runtime).isReady)
        var manager = BrowserProcessManager(paths: paths)
        defer { manager.stop(profileID: profile.id) }
        let portFile = paths.browserDataDirectory(for: profile.id).appendingPathComponent("DevToolsActivePort")
        func start() throws {
            try? FileManager.default.removeItem(at: portFile)
            try manager.launch(profile: profile, runtime: runtime, additionalArguments: [
                "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
                "--disable-background-networking", "--disable-component-update", "--disable-sync"
            ])
        }
        func page() async throws -> URL {
            for _ in 0..<100 {
                if let port = try? String(contentsOf: portFile, encoding: .utf8).split(separator: "\n").first,
                   let listURL = URL(string: "http://127.0.0.1:\(port)/json/list"),
                   let (data, _) = try? await URLSession.shared.data(from: listURL),
                   let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let target = targets.first(where: { ($0["url"] as? String)?.hasPrefix(server.url.absoluteString) == true }),
                   let websocket = target["webSocketDebuggerUrl"] as? String, let url = URL(string: websocket) { return url }
                try await Task.sleep(for: .milliseconds(100))
            }
            print("STORAGE_FIXTURE page timeout state=\(manager.processState(for: profile.id))")
            throw FixtureError.timeout
        }
        func stopped() async throws {
            manager.reconcile(profiles: [profile])
            for _ in 0..<150 {
                if manager.processState(for: profile.id) == .stopped { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            print("STORAGE_FIXTURE stop timeout state=\(manager.processState(for: profile.id)) error=\(manager.lastError ?? "none")")
            throw FixtureError.timeout
        }
        let read = """
        (async()=>{ const db=await new Promise((ok,no)=>{const r=indexedDB.open('fixture',1);r.onupgradeneeded=()=>r.result.createObjectStore('values');r.onsuccess=()=>ok(r.result);r.onerror=()=>no(r.error)}); const value=await new Promise((ok,no)=>{const r=db.transaction('values').objectStore('values').get('key');r.onsuccess=()=>ok(r.result);r.onerror=()=>no(r.error)});db.close();return JSON.stringify({persistent:document.cookie.includes('persistent=synthetic'),session:document.cookie.includes('session=synthetic'),local:localStorage.getItem('fixture')==='synthetic',idb:value==='synthetic'});})()
        """
        func verify(_ phase: String) async throws {
            let text = try await Self.evaluate(read, at: page())
            let result = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Bool])
            #expect(result["persistent"] == true)
            #expect(result["local"] == true)
            #expect(result["idb"] == true)
            // Session-cookie expiration is recorded separately: the unchanged
            // runtime startup policy does not promise session restoration.
            print("STORAGE_FIXTURE \(phase) persistent=\(result["persistent"] == true) local=\(result["local"] == true) idb=\(result["idb"] == true) session=\(result["session"] == true)")
        }
        try start()
        _ = try await Self.evaluate("""
        (async()=>{document.cookie='persistent=synthetic; Max-Age=3600; Path=/';document.cookie='session=synthetic; Path=/';localStorage.setItem('fixture','synthetic');const db=await new Promise((ok,no)=>{const r=indexedDB.open('fixture',1);r.onupgradeneeded=()=>r.result.createObjectStore('values');r.onsuccess=()=>ok(r.result);r.onerror=()=>no(r.error)});await new Promise((ok,no)=>{const t=db.transaction('values','readwrite');t.objectStore('values').put('synthetic','key');t.oncomplete=ok;t.onerror=()=>no(t.error)});db.close();return 'seeded'})()
        """, at: page())
        try await verify("initial")
        // A second fresh manager reconciles the still-running synthetic browser.
        let restarted = BrowserProcessManager(paths: paths)
        restarted.reconcile(profiles: [profile])
        try await Task.sleep(for: .seconds(1))
        #expect(restarted.processState(for: profile.id).isRunning)
        try await verify("manager-restart-browser-running")
        let startupLock = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: paths.lockFile(for: profile.id))) as? [String: Any])
        let startupPID = try #require(startupLock["pid"] as? Int32)
        for _ in 0..<50 {
            if NSRunningApplication(processIdentifier: startupPID)?.isFinishedLaunching == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("STORAGE_FIXTURE macOS_finished_launching=\(NSRunningApplication(processIdentifier: startupPID)?.isFinishedLaunching == true)")
        if environment["NEANTIK_STORAGE_APP_QUIT_CONTROL"] == "1" {
            let lockData = try Data(contentsOf: paths.lockFile(for: profile.id))
            let lock = try #require(JSONSerialization.jsonObject(with: lockData) as? [String: Any])
            let pid = try #require(lock["pid"] as? Int32)
            let app = try #require(NSRunningApplication(processIdentifier: pid))
            #expect(app.terminate())
        } else { manager.stop(profileID: profile.id) }
        try await stopped()
        print("STORAGE_FIXTURE stop completed")
        manager = BrowserProcessManager(paths: paths)
        try start()
        try await verify("clean-stop-and-relaunch")
        // Crash only the fixture browser via its own CDP endpoint, never PID
        // discovery or signaling of any production browser.
        let crashPage = try await page()
        _ = try? await Self.command("Browser.crash", params: [:], at: crashPage)
        try await stopped()
        manager = BrowserProcessManager(paths: paths)
        try start()
        try await verify("controlled-crash-and-relaunch")
        manager.stop(profileID: profile.id)
        try await stopped()
        try FileManager.default.removeItem(at: root)
    }

    @Test func preparedHTTPProxyUsesRuntimeAndFailsClosedWhenUnavailable() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEANTIK_RUN_LIVE_PROXY"] == "1",
              let app = environment["NEANTIK_LIVE_AUDIT_APP"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-proxy-fixture-\(UUID())")
        let paths = AppPaths(rootDirectory: root)
        let server = try await FingerprintAuditLoopbackServer.start()
        defer { server.stop() }
        let store = ProfileStore(paths: paths)
        var draft = BrowserProfile(name: "Synthetic HTTP proxy", startURL: "http://neantik-proxy-fixture.invalid/",
            proxy: ProxyConfiguration(kind: .http, host: "127.0.0.1", port: try #require(server.url.port), username: ""))
        draft.identity = draft.identity.replacingProxyContext(timezoneIdentifier: "America/New_York", localeIdentifier: "en-US", evidence: .ipAPI(observedAt: Date()))
        let profile = try store.upsert(draft)
        let runtime = BrowserRuntime(name: "NeAntik Browser", executableURL: URL(fileURLWithPath: app).appendingPathComponent("Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser"), source: "Exact runtime proxy fixture", flavor: .fingerprintChromium)
        let manager = BrowserProcessManager(paths: paths)
        defer { manager.stop(profileID: profile.id) }
        let observedAt = try #require(profile.identity.proxyContextEvidence?.observedAt)
        let health = ProxyHealthUpdatePolicy.success(ProxyTestObservation(observedAt: observedAt, responseTimeMilliseconds: 1,
            result: ProxyTestResult(ipAddress: "127.0.0.1", city: nil, countryName: nil, countryCode: nil, timezoneIdentifier: "America/New_York", localeIdentifier: "en-US")))
        let receipt = try #require(BrowserLaunchPreparationPolicy.receipt(profile: profile, proxyHealth: health))
        try manager.launch(profile: profile, runtime: runtime, preparationReceipt: receipt, additionalArguments: [
            "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
            "--disable-background-networking", "--disable-component-update", "--disable-sync"
        ])
        let portFile = paths.browserDataDirectory(for: profile.id).appendingPathComponent("DevToolsActivePort")
        var page: URL?
        for _ in 0..<100 where page == nil {
            if let port = try? String(contentsOf: portFile, encoding: .utf8).split(separator: "\n").first,
               let url = URL(string: "http://127.0.0.1:\(port)/json/list"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let target = targets.first(where: { ($0["url"] as? String) == profile.startURL }),
               let socket = target["webSocketDebuggerUrl"] as? String { page = URL(string: socket) }
            if page == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let socket = try #require(page)
        // The .invalid destination cannot serve this loopback fixture directly.
        var title = ""
        for _ in 0..<100 where title != "Проверка отпечатка NeAntik" {
            title = try await Self.evaluate("document.title", at: socket)
            if title != "Проверка отпечатка NeAntik" { try await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(title == "Проверка отпечатка NeAntik")
        server.stop()
        let navigation = try await Self.command("Page.navigate", params: ["url": profile.startURL + "unavailable-\(UUID())"], at: socket)
        let result = try #require(navigation["result"] as? [String: Any])
        #expect(result["errorText"] as? String == "net::ERR_PROXY_CONNECTION_FAILED")
        let lockData = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.lockFile(for: profile.id))) as? [String: Any]
        let pid = try #require(lockData?["pid"] as? Int32)
        for _ in 0..<100 where NSRunningApplication(processIdentifier: pid)?.isFinishedLaunching != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(NSRunningApplication(processIdentifier: pid)?.isFinishedLaunching == true)
        manager.stop(profileID: profile.id)
        for _ in 0..<150 where manager.processState(for: profile.id) != .stopped {
            try await Task.sleep(for: .milliseconds(100))
        }
        if manager.processState(for: profile.id) != .stopped {
            print("PROXY_FIXTURE stop_failed=\(manager.lastError ?? "none")")
            _ = try? await Self.command("Browser.close", params: [:], at: socket)
        }
        try #require(manager.processState(for: profile.id) == .stopped)
        if manager.processState(for: profile.id) == .stopped { try FileManager.default.removeItem(at: root) }
        print("PROXY_FIXTURE route=loopback-http unavailable=fail-closed credentials=none")
    }

    private static func evaluate(_ expression: String, at url: URL) async throws -> String {
        for attempt in 0..<20 {
            do {
                let response = try await command("Runtime.evaluate", params: ["expression": expression, "awaitPromise": true, "returnByValue": true], at: url)
                if let result = response["result"] as? [String: Any], result["exceptionDetails"] == nil,
                   let object = result["result"] as? [String: Any], let value = object["value"] as? String { return value }
            } catch {
                if attempt == 19 { throw error }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw FixtureError.invalidResponse
    }

    private static func command(_ method: String, params: [String: Any], at url: URL) async throws -> [String: Any] {
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url); socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        let timeout = Task { try await Task.sleep(for: .seconds(10)); socket.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel() }
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let data: Data
            switch message { case .string(let text): data = Data(text.utf8); case .data(let value): data = value; @unknown default: continue }
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], response["id"] as? Int == 1 else { continue }
            return response
        }
    }
    enum FixtureError: Error { case timeout, invalidResponse }
}
