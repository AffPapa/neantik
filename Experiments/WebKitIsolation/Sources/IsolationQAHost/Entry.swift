import AppKit
import WebKit
import Darwin
import IsolationCore

/// Dedicated QA process, never the production manager or a real profile.
/// No automatic navigation: a native stage must supply its own local endpoint.
@MainActor private final class Host: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var view: WKWebView?
    private let address = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "Пустое временное хранилище. Только собственные локальные endpoints; это не рабочий профиль.")
    func applicationDidFinishLaunching(_ notification: Notification) {
        let id = Bundle.main.bundleIdentifier ?? ""
        guard ["app.neantik.desktop.network-qa.profilehost", "app.neantik.desktop.network-qa.control"].contains(id) else { NSApp.terminate(nil); return }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration); view = web; web.navigationDelegate = self
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        w.title = id.hasSuffix(".control") ? "NeAntik Isolation QA · B Direct" : "NeAntik Isolation QA · A guarded"
        let open = NSButton(title: "Открыть свой endpoint", target: self, action: #selector(navigate))
        let row = NSStackView(views: [address, open]); row.orientation = .horizontal
        let stack = NSStackView(views: [status,row,web]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 16),stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -16),stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 16),stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -16),row.widthAnchor.constraint(equalTo: stack.widthAnchor),web.widthAnchor.constraint(equalTo: stack.widthAnchor),web.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)])
        address.placeholderString = "Собственный HTTP endpoint с QA run path из preparation.json"; address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        window = w; w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func allowed(_ url: URL) -> Bool {
        guard let run = Bundle.main.object(forInfoDictionaryKey: "NeAntikQARunID") as? String else { return false }
        return OwnedQATargetPolicy.permits(url, runID: run)
    }
    @objc private func navigate() {
        guard let url = URL(string: address.stringValue), allowed(url) else { status.stringValue = "Нужен HTTP endpoint на собственном loopback/private IP с явным портом."; return }
        status.stringValue = "Запрос начат. Сам факт ошибки не доказывает блокировку: нужны независимые счётчики origin/provider и B."
        view?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url.map(allowed) == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { status.stringValue = "Документ загружен. Маршрут определяется отдельно по собственным счётчикам." }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let value = error as NSError
        let domain = [NSURLErrorDomain, WKError.errorDomain].contains(value.domain) ? value.domain : "другой домен"
        // userInfo and localizedDescription may contain URLs or personal data.
        status.stringValue = "Загрузка не завершена (\(domain), код \(value.code)). Без provider/origin/B это не PASS."
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { view?.stopLoading(); view?.navigationDelegate = nil; window?.contentView = nil; view = nil }
}
@main enum Main {
    @MainActor static func main() {
        guard Bundle.main.bundleIdentifier?.hasPrefix("app.neantik.desktop.network-qa.") == true else { exit(78) }
        let app = NSApplication.shared, delegate = Host(); app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
