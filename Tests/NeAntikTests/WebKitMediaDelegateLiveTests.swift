import AppKit
import Foundation
import Testing
import WebKit
@testable import NeAntik

@MainActor private final class MediaFrameProbe: NSObject, WKNavigationDelegate {
    var frame: WKFrameInfo?
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.sourceFrame.securityOrigin.protocol == "http" { frame = action.sourceFrame }
        decisionHandler(.allow)
    }
}

/// Uses real headed WKWebViews and native WKFrameInfo, invoking only our public
/// delegate bridge. No getUserMedia, hardware capture or TCC prompt is requested.
/// This does NOT qualify engine dispatch or a formerly granted site's cache.
@Suite(.serialized) @MainActor struct WebKitMediaDelegateLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_MEDIA_DELEGATE_LIVE"] == "1"))
    func ownedForeignBackgroundAndClosedFrameDecisions() async throws {
        _ = NSApplication.shared
        let env = ProcessInfo.processInfo.environment
        let text = try #require(env["NEANTIK_WEBKIT_CACHE_FIXTURE_URL"])
        let url = try #require(URL(string: text))
        try #require(url.scheme == "http" && url.host == "127.0.0.1" && url.user == nil && url.password == nil)
        let root = URL(fileURLWithPath: try #require(env["NEANTIK_WEBKIT_CACHE_OWNED_RUN_ROOT"])).resolvingSymlinksInPath()
        try #require(root.deletingLastPathComponent() == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath())
        try #require(root.lastPathComponent.hasPrefix("neantik-cache-native-"))
        try #require(UUID(uuidString: String(root.lastPathComponent.dropFirst("neantik-cache-native-".count))) != nil)
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let ask = try store.upsert(BrowserProfile(name: "Owned delegate ask", startURL: url.appendingPathComponent("page").absoluteString, engine: .webkit))
        let deny = try store.upsert(BrowserProfile(name: "Owned delegate deny", startURL: ask.startURL, engine: .webkit, webKitMediaPolicy: .deny))
        try paths.writePrivateFile(try JSONEncoder().encode([ask.id, deny.id]), to: root.appendingPathComponent("owned-stores.json"))
        func browser(_ p: BrowserProfile) throws -> WebKitProfileBrowser {
            try WebKitProfileBrowser(profile: p, lease: paths.acquireWebKitSessionGuard(for: p.id),
                metadataLease: paths.acquireWebKitMetadataGuard(for: p.id), onClose: {})
        }
        let a = try browser(ask), b = try browser(deny)
        defer { a.close(); b.close() }
        a.show(); b.show()
        func frame(_ view: WKWebView) async throws -> WKFrameInfo {
            let probe = MediaFrameProbe(); view.navigationDelegate = probe
            view.load(URLRequest(url: url.appendingPathComponent("page")))
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < deadline {
                if !view.isLoading, (try? await view.evaluateJavaScript("window.neantikOwnCacheFixture === true")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(!view.isLoading && view.url?.host == "127.0.0.1")
            view.load(URLRequest(url: url.appendingPathComponent("second")))
            while probe.frame == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            return try #require(probe.frame)
        }
        let first = a.webView, af = try await frame(first), bf = try await frame(b.webView)
        first.navigationDelegate = a; b.webView.navigationDelegate = b
        func decision(_ browser: WebKitProfileBrowser, view: WKWebView, frame: WKFrameInfo,
                      type: WKMediaCaptureType) -> WKPermissionDecision? {
            var calls = 0, observed: WKPermissionDecision?
            browser.webView(view, requestMediaCapturePermissionFor: frame.securityOrigin,
                initiatedByFrame: frame, type: type) { calls += 1; observed = $0 }
            #expect(calls == 1)
            return observed
        }
        for type in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
            #expect(decision(a, view: first, frame: af, type: type) == .prompt)
            #expect(decision(b, view: b.webView, frame: bf, type: type) == .deny)
            #expect(decision(a, view: b.webView, frame: bf, type: type) == .deny)
            #expect(decision(a, view: first, frame: bf, type: type) == .deny)
        }
        let second = try #require(a.openTab(at: url.appendingPathComponent("page")))
        let sf = try await frame(second); second.navigationDelegate = a
        #expect(decision(a, view: first, frame: af, type: .camera) == .prompt) // Background belongs to same profile.
        #expect(decision(a, view: second, frame: sf, type: .microphone) == .prompt)
        let selected = a.selectedTabID; a.closeTab(selected)
        #expect(decision(a, view: second, frame: sf, type: .camera) == .deny)
        var edit = ask; edit.webKitMediaPolicy = .deny
        #expect(throws: Error.self) { try store.upsert(edit) }
        a.close(); b.close()
        #expect(decision(a, view: first, frame: af, type: .camera) == .deny)
        // Full close releases the metadata fence; next session uses saved deny.
        _ = try store.upsert(edit)
    }
}
