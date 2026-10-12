import AppKit
import WebKit

enum BrowserEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case chromium
    case webkit

    var id: String { rawValue }
    var title: String { self == .chromium ? "Chromium" : "WebKit · движок Safari" }
}

enum WebKitProfileError: LocalizedError {
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        }
    }
}

/// Public system WebKit does not inherit Chromium's fingerprint or route
/// policies. Refuse unsupported launches before constructing a web view.
enum WebKitProfilePolicy {
    static func validate(_ profile: BrowserProfile) throws {
        guard !profile.isArchived else { throw NeAntikError.profileArchived }
        try validateConfiguration(profile)
    }

    static func validateConfiguration(_ profile: BrowserProfile) throws {
        guard profile.engine == .webkit,
              profile.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw NeAntikError.invalidProfile
        }
        guard profile.proxy == nil else {
            throw WebKitProfileError.unsupported("Прокси для WebKit пока не проверены. Запуск отменён: прямое подключение вместо прокси не выполняется. Для работы с прокси создай профиль Chromium.")
        }
        guard profile.startupMode == .startPage else {
            throw WebKitProfileError.unsupported("WebKit пока открывает стартовую страницу. Восстановление вкладок доступно для Chromium.")
        }
        guard let url = BrowserLaunchBuilder.validatedStartURL(profile.startURL), permits(url) else {
            throw NeAntikError.invalidProfile
        }
    }

    static func permits(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank"
    }
}

@MainActor
private final class WebKitBrowserWindow: NSWindow {
    weak var browser: WebKitProfileBrowser?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if browser?.handleCommand(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

enum WebKitWindowCommand: Equatable {
    case address, reload, close, back, forward
    static func resolve(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        guard modifiers.intersection([.command, .option, .control, .shift]) == .command else { return nil }
        switch characters?.lowercased() {
        case "l": return .address
        case "r": return .reload
        case "w": return .close
        case "[": return .back
        case "]": return .forward
        default: break
        }
        // A Cyrillic layout reports Cyrillic characters for these physical
        // keys. Keep the usual Mac shortcuts without intercepting plain input.
        guard characters?.unicodeScalars.contains(where: { !$0.isASCII }) == true else { return nil }
        switch keyCode { case 37: return .address; case 15: return .reload; case 13: return .close; case 33: return .back; case 30: return .forward; default: return nil }
    }
}

/// One profile owns one window and a stable persistent UUID data store.
/// The process guard is held for the entire window lifetime; another manager
/// cannot edit, launch or run Chromium maintenance against this profile.
@MainActor
final class WebKitProfileBrowser: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let profileID: UUID
    let webView: WKWebView
    private let window: WebKitBrowserWindow
    private let address = NSTextField()
    private let message = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private var observations: [NSKeyValueObservation] = []
    private var commandMonitor: Any?
    private var lease: PrivateFileGuardLease?
    private var metadataLease: PrivateFileGuardLease?
    private var onClose: (() -> Void)?

    init(profile: BrowserProfile, lease: PrivateFileGuardLease, metadataLease: PrivateFileGuardLease, onClose: @escaping () -> Void) throws {
        try WebKitProfilePolicy.validate(profile)
        profileID = profile.id
        self.lease = lease
        self.metadataLease = metadataLease
        self.onClose = onClose
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.id)
        // Never use the default (shared) store, inject a UA, or reuse a
        // Chromium identity seed. The system engine supplies its actual APIs.
        configuration.websiteDataStore.proxyConfigurations = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = WebKitBrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.browser = self
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = "\(profile.name) — WebKit · NeAntik"
        window.minSize = NSSize(width: 640, height: 420)
        window.center()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        address.placeholderString = "Адрес сайта"
        address.font = .systemFont(ofSize: 14)
        address.delegate = self
        address.target = self
        address.action = #selector(openAddress)
        address.setAccessibilityLabel("Адрес сайта")
        let bar = NSStackView(views: [button(backButton, title: "←", help: "Назад · ⌘[", action: #selector(back)),
            button(forwardButton, title: "→", help: "Вперёд · ⌘]", action: #selector(forward)),
            button(NSButton(), title: "↻", help: "Обновить · ⌘R", action: #selector(reload)), address])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2
        message.stringValue = "WebKit · отдельные данные сайтов · параметры устройства определяет macOS"
        let content = NSView()
        window.contentView = content
        for view in [bar, webView, message] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor), webView.leadingAnchor.constraint(equalTo: content.leadingAnchor), webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            message.topAnchor.constraint(equalTo: webView.bottomAnchor, constant: 6), message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), message.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6)
        ])
        observations = [webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshNavigation() }
        }, webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshNavigation() }
        }, webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshNavigation() }
        }]
        refreshNavigation()
        // WKWebView may consume key equivalents before NSWindow's responder
        // path. Observe only this window's command events, never other apps.
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleCommand(event) ? nil : event
        }
        if let startURL = BrowserLaunchBuilder.validatedStartURL(profile.startURL) { webView.load(URLRequest(url: startURL)) }
    }

    private func button(_ button: NSButton, title: String, help: String, action: Selector) -> NSButton {
        button.title = title; button.bezelStyle = .rounded; button.toolTip = help
        button.setAccessibilityLabel(help); button.target = self; button.action = action
        return button
    }

    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func close() { window.performClose(nil) }
    func focusAddress() { window.makeFirstResponder(address); address.selectText(nil) }
    fileprivate func handleCommand(_ event: NSEvent) -> Bool {
        guard let command = WebKitWindowCommand.resolve(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
        switch command { case .address: focusAddress(); case .reload: reload(); case .close: close(); case .back: back(); case .forward: forward() }
        return true
    }
    @objc func back() { webView.goBack() }
    @objc func forward() { webView.goForward() }
    @objc func reload() { webView.reload() }
    @objc private func openAddress() {
        guard let url = BrowserLaunchBuilder.validatedStartURL(address.stringValue), WebKitProfilePolicy.permits(url) else {
            message.stringValue = "Введи адрес http:// или https://. Для пустой страницы — about:blank."
            return
        }
        webView.load(URLRequest(url: url)); window.makeFirstResponder(webView)
    }
    private func refreshNavigation() {
        if window.firstResponder !== address.currentEditor() { address.stringValue = webView.url?.absoluteString ?? "" }
        backButton.isEnabled = webView.canGoBack; forwardButton.isEnabled = webView.canGoForward
    }
    func windowWillClose(_ notification: Notification) {
        webView.stopLoading(); observations.removeAll()
        if let commandMonitor { NSEvent.removeMonitor(commandMonitor); self.commandMonitor = nil }
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        // AppKit may retain a closed window. Detach its content so that the
        // window cannot keep a website data store/session alive after close.
        window.contentView = nil
        window.delegate = nil; window.browser = nil
        let callback = onClose; onClose = nil
        metadataLease?.release(); metadataLease = nil
        lease?.release(); lease = nil
        callback?()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, WebKitProfilePolicy.permits(url) else {
            message.stringValue = "Этот тип ссылки пока не поддерживается в WebKit-профиле."
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Keep popup navigation within the same profile; never launch Safari
        // or create an unconfigured view backed by a shared data store.
        if let url = action.request.url, WebKitProfilePolicy.permits(url) { webView.load(action.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        message.stringValue = "WebKit · отдельные данные сайтов · параметры устройства определяет macOS"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        // Do not display an NSError's URL/userinfo: it may contain secrets.
        message.stringValue = "Не удалось открыть страницу. Проверь адрес и подключение к сети; затем обнови страницу."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        message.stringValue = "Процесс страницы завершился. Нажми «Обновить», чтобы открыть её снова."
    }
}
