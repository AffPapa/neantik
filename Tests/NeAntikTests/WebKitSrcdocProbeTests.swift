import AppKit
import Foundation
import Testing
import WebKit
@testable import NeAntik

@MainActor
private final class SrcdocNavigationProbe: NSObject, WKNavigationDelegate {
    var observations: [String] = []
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.absoluteString ?? "none"
        let frame = action.targetFrame?.isMainFrame == true ? "main" : "subframe-or-new"
        observations.append("\(scheme):\(frame)")
        decisionHandler(.allow)
    }
}

@MainActor
@Suite(.serialized)
struct WebKitSrcdocProbeTests {
    @Test func syntheticSrcdocExecutesWithProductNavigationDelegate() async throws {
        _ = NSApplication.shared
        let html = """
        <!doctype html><html><body><script>
        window.frameOK = false;
        window.addEventListener('message', event => { if (event.data === 'neantik-srcdoc-ok') window.frameOK = true; });
        </script><iframe srcdoc="&lt;script&gt;parent.postMessage('neantik-srcdoc-ok','*')&lt;/script&gt;"></iframe></body></html>
        """
        let observer = SrcdocNavigationProbe()
        let control = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        control.navigationDelegate = observer
        control.loadHTMLString(html, baseURL: nil)
        guard await frameExecuted(control) else {
            throw WebKitProfileError.unsupported("srcdoc positive control did not run; fixture inconclusive")
        }
        print("SRCDOC_CONTROL_NAVIGATION=\(observer.observations.joined(separator: ","))")
        #expect(observer.observations.contains("about:srcdoc:subframe-or-new"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-srcdoc-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let profile = try store.upsert(BrowserProfile(name: "Synthetic srcdoc", startURL: "about:blank", engine: .webkit))
        let lease = try paths.acquireWebKitSessionGuard(for: profile.id)
        let metadataLease = try paths.acquireWebKitMetadataGuard(for: profile.id)
        let productExecuted: Bool
        do {
            let browser = try WebKitProfileBrowser(profile: profile, lease: lease, metadataLease: metadataLease, onClose: {})
            defer { browser.close() }
            let view = browser.webView
            view.loadHTMLString(html, baseURL: nil)
            productExecuted = await frameExecuted(view)
        }
        print("SRCDOC_PRODUCT_FRAME_EXECUTED=\(productExecuted)")
        #expect(productExecuted)
        try await Task.sleep(for: .milliseconds(200))
        let removalError: Error? = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.remove(forIdentifier: profile.id) { error in continuation.resume(returning: error) }
        }
        #expect(removalError == nil)
    }

    @Test func navigationAllowsSrcdocOnlyForKnownSubframes() throws {
        let srcdoc = try #require(URL(string: "about:srcdoc"))
        #expect(WebKitProfilePolicy.permitsNavigation(srcdoc, isSubframe: true))
        #expect(!WebKitProfilePolicy.permitsNavigation(srcdoc, isSubframe: false))
        for value in ["about:srcdoc#fragment", "about:srcdoc?query", "data:text/html,hello", "blob:https://example.com/id", "file:///tmp/a", "javascript:alert(1)"] {
            let url = try #require(URL(string: value))
            #expect(!WebKitProfilePolicy.permitsNavigation(url, isSubframe: true))
            #expect(!WebKitProfilePolicy.permitsNavigation(url, isSubframe: false))
        }
        #expect(WebKitProfilePolicy.permitsNavigation(try #require(URL(string: "https://example.com/")), isSubframe: false))
    }

    private func frameExecuted(_ view: WKWebView) async -> Bool {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if (try? await view.evaluateJavaScript("window.frameOK === true")) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
