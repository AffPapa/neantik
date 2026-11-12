import AppKit
import Foundation
import Testing
import WebKit
@testable import NeAntik

@Suite(.serialized)
@MainActor
struct WebKitPeerConnectionLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_LIVE"] == "1"))
    func peerConnectionBlockAppliesAcrossProfileAndNewTab() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_FIXTURE_URL"])
        let url = try #require(URL(string: fixture))
        try #require(url.scheme == "http" && url.host == "127.0.0.1" && url.path == "/fixture"
                     && url.port != nil && url.user == nil && url.password == nil
                     && url.query == nil && url.fragment == nil)
        _ = NSApplication.shared
        let root = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: FileManager.default.temporaryDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let profiles = [false, true].map { blocked in
            BrowserProfile(name: "WebKit RTC QA", startURL: fixture, engine: .webkit,
                           webKitBlockPeerConnections: blocked)
        }
        do {
            for profile in profiles {
                try await verify(profile, paths: paths, url: url)
            }
        } catch {
            for profile in profiles {
                try? await removeStore(profile.id)
            }
            throw error
        }
        for profile in profiles {
            try await removeStore(profile.id)
        }
    }

    private func verify(_ profile: BrowserProfile, paths: AppPaths, url: URL) async throws {
        let session = try paths.acquireWebKitSessionGuard(for: profile.id)
        let metadata = try paths.acquireWebKitMetadataGuard(for: profile.id)
        let browser = try WebKitProfileBrowser(profile: profile, lease: session, metadataLease: metadata, onClose: {})
        defer { browser.close() }
        browser.show()
        let expected = !profile.webKitBlockPeerConnections
        #expect(try await canOpenDataChannel(in: browser.webView, at: url) == expected)
        let tab = try #require(browser.openTab(at: url))
        #expect(try await canOpenDataChannel(in: tab, at: url) == expected)
    }

    private func removeStore(_ id: UUID) async throws {
        try await Task.sleep(for: .milliseconds(200))
        let error: Error? = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.remove(forIdentifier: id) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
    }

    private func canOpenDataChannel(in view: WKWebView, at url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if view.url == url, !view.isLoading,
               (try? await view.evaluateJavaScript("window.neantikOwnFixture === true && isSecureContext")) as? Bool == true {
                // No offer, ICE gathering, media capture or remote services.
                let result = try await view.evaluateJavaScript("""
                    (() => {
                        if (typeof RTCPeerConnection !== 'function') return false;
                        const connection = new RTCPeerConnection({ iceServers: [] });
                        try {
                            const channel = connection.createDataChannel('owned-qa');
                            channel.close();
                            return true;
                        } finally {
                            connection.close();
                        }
                    })()
                    """)
                return try #require(result as? Bool)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WebKitProfileError.unsupported("Owned WebKit fixture did not load in the peer connection test")
    }
}
