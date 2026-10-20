import AppKit
import Network
import WebKit

enum BrowserEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case chromium
    case webkit

    var id: String { rawValue }
    var title: String { self == .chromium ? "Chromium" : "WebKit · движок Safari" }

    /// Static engine support, not evidence that a particular session or route
    /// was measured. Never include profile identity, visits or credentials.
    var managementCapabilities: [String: Bool] {
        let configuredEngine = self == .chromium
        let proxy = configuredEngine || (self == .webkit && WebKitProxyFeature.launchEnabled)
        return ["persistentSiteData": true,
                "fingerprintConfiguration": configuredEngine,
                "proxy": proxy, "mcpLaunch": true,
                "extensions": configuredEngine, "browserDataBackup": configuredEngine]
    }

    var settingsSummary: String {
        self == .chromium
            ? "Встроенный Chromium: изолированные профили, прокси и параметры браузерного окружения."
            : Self.webKitSettingsSummary
    }

    private static var webKitSettingsSummary: String {
        return "Системный WebKit в окне NeAntik: отдельные cookies, данные сайтов и вкладки. Прокси WebKit отключён во всех сборках до включения и проверки отдельного runtime. Отпечаток, язык и часовой пояс берутся из macOS; подмена этих параметров не поддерживается. Для запуска через AI включи доступ WebKit в справке MCP и разреши выбранные профили. Расширения и настройки Chromium доступны только в Chromium."
    }
}

/// Runtime choice is explicit. An owned session carries only the short-lived
/// broker credential; upstream proxy credentials stay in the manager/broker.
enum WebKitProfileBrowserRuntime {
    case system
    case owned(session: WebKitHostIPC.Session,
               relayCredential: WebKitHostIPC.RelayCredential)
}

enum WebKitProfileError: LocalizedError {
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let reason): return reason
        }
    }
}

/// System WebKit has its own APIs and networking. Refuse unsupported launches
/// before constructing views rather than falling back to another route.
enum WebKitProfilePolicy {
    static let maximumTabs = 32
    static func canOpenTab(count: Int) -> Bool { (0..<maximumTabs).contains(count) }
    static func validate(_ profile: BrowserProfile) throws {
        guard !profile.isArchived else { throw NeAntikError.profileArchived }
        try validateConfiguration(profile)
        guard profile.webKitRuntimeGeneration == .system else {
            throw WebKitProfileError.unsupported("Для этого профиля нужен отдельный WebKit runtime, который ещё не включён в приложение. Данные не открывались и не изменены.")
        }
        guard profile.proxy == nil || WebKitProxyFeature.launchEnabled else {
            throw WebKitProfileError.unsupported("Прокси WebKit пока отключён: маршрут не прошёл квалификацию. Настройки профиля сохранены; прямое подключение вместо прокси не выполняется.")
        }
        try validateNativeContext(profile)
    }

    /// Owned WebKit accepts only the exact immutable isolated-runtime session
    /// that the authenticated parent bootstrapped. It still uses the native
    /// WebKit platform identity; this is not a Chromium fingerprint mode.
    static func validateOwnedRuntime(_ profile: BrowserProfile,
                                     session: WebKitHostIPC.Session) throws {
        guard !profile.isArchived else { throw NeAntikError.profileArchived }
        try validateConfiguration(profile)
        guard profile.webKitRuntimeGeneration == .isolatedV1,
              session.isValid(), session.profileID == profile.id,
              session.revision == profile.revision else {
            throw WebKitProfileError.unsupported("Изолированный WebKit-сеанс не совпадает с сохранённой версией профиля. Данные не открывались и не изменены.")
        }
        try validateNativeContext(profile)
    }

    private static func validateNativeContext(_ profile: BrowserProfile) throws {
        // Keep legacy metadata readable and unchanged; reject an unsupported
        // launch rather than silently ignoring explicit Chromium context.
        guard profile.identity.timezoneIdentifier == nil,
              profile.identity.localeIdentifier == nil,
              profile.identity.proxyContextEvidence == nil else {
            throw WebKitProfileError.unsupported("В этом WebKit-профиле сохранены язык или часовой пояс Chromium. WebKit использует параметры macOS и не может применить эту настройку. Запуск отменён; для настройки окружения создай профиль Chromium.")
        }
        guard profile.webKitMediaPolicy == .ask || WebKitMediaFeature.isEnabled else {
            throw WebKitProfileError.unsupported("Настройки камеры и микрофона WebKit ещё проходят проверку. Этот профиль требует версии с поддержкой этой настройки; запуск отменён.")
        }
    }

    static func validateConfiguration(_ profile: BrowserProfile) throws {
        guard profile.engine == .webkit,
              profile.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw NeAntikError.invalidProfile
        }
        guard profile.fontPolicy == .native else {
            throw UnsupportedBrowserFontPolicyError()
        }
        if let proxy = profile.proxy, !proxy.isValid {
            throw NeAntikError.invalidProfile
        }
        guard let url = BrowserLaunchBuilder.validatedStartURL(profile.startURL), permits(url) else {
            throw NeAntikError.invalidProfile
        }
    }

    static func permits(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank"
    }

    static func permitsPopup(profileID: UUID, openerIsOwned: Bool, storeID: UUID?, persistent: Bool, url: URL?) -> Bool {
        guard openerIsOwned, persistent, storeID == profileID, let url else { return false }
        return permits(url)
    }
}

/// Keep selection stable when a background tab closes; closing the selected
/// tab chooses its right neighbour, or the last remaining tab at the edge.
struct WebKitTabOrder {
    private(set) var ids: [UUID]
    private(set) var selected: UUID
    init(first: UUID) { ids = [first]; selected = first }
    mutating func append(_ id: UUID) {
        guard !ids.contains(id) else { return }
        ids.append(id); selected = id
    }
    @discardableResult mutating func select(_ id: UUID) -> Bool {
        guard ids.contains(id) else { return false }
        selected = id; return true
    }
    @discardableResult mutating func remove(_ id: UUID) -> Bool {
        guard ids.count > 1, let index = ids.firstIndex(of: id) else { return false }
        ids.remove(at: index)
        if selected == id { selected = ids[min(index, ids.count - 1)] }
        return true
    }
    mutating func cycle(_ direction: Int) {
        guard let index = ids.firstIndex(of: selected) else { return }
        selected = ids[(index + (direction < 0 ? ids.count - 1 : 1)) % ids.count]
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
    case address, reload, close, back, forward, newTab, previousTab, nextTab
    static func resolve(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self? {
        let keys = modifiers.intersection([.command, .option, .control, .shift])
        if keys == [.command, .shift] {
            switch keyCode { case 33: return .previousTab; case 30: return .nextTab; default: return nil }
        }
        guard keys == .command else { return nil }
        switch characters?.lowercased() {
        case "l": return .address
        case "r": return .reload
        case "w": return .close
        case "t": return .newTab
        case "[": return .back
        case "]": return .forward
        default: break
        }
        // Preserve familiar shortcuts with a Cyrillic keyboard layout, while
        // leaving ordinary text and other modifier combinations untouched.
        guard characters?.unicodeScalars.contains(where: { !$0.isASCII }) == true else { return nil }
        switch keyCode {
        case 37: return .address
        case 15: return .reload
        case 13: return .close
        case 17: return .newTab
        case 33: return .back
        case 30: return .forward
        default: return nil
        }
    }
}

@MainActor
private final class WebKitBrowserTab {
    let id = UUID()
    let view: WKWebView
    let titleButton = NSButton()
    let closeButton = NSButton()
    let row = NSStackView()
    var observations: [NSKeyValueObservation] = []
    var status = "WebKit · данные этого профиля · параметры устройства определяет macOS"
    var committedURL = "about:blank"
    init(view: WKWebView) { self.view = view }
    func detach(preserveNavigationDelegate: Bool = false) {
        observations.removeAll()
        // Public APIs stop any active capture before a tab is detached. They
        // do not replace the deny policy for future capture requests.
        view.setCameraCaptureState(.none, completionHandler: nil)
        view.setMicrophoneCaptureState(.none, completionHandler: nil)
        // stopLoading can abort policy→download conversion without delivering
        // didBecome. Keep that view only until its reserved conversion arrives,
        // then cancel the actual WKDownload and stop the navigation.
        if !preserveNavigationDelegate { view.stopLoading(); view.navigationDelegate = nil }
        view.uiDelegate = nil
        view.removeFromSuperview(); row.removeFromSuperview()
    }
}

/// A profile owns one window with tabs and one persistent UUID data store.
/// Lifetime guards belong to the whole window, not to an individual tab.
@MainActor
final class WebKitProfileBrowser: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let profileID: UUID
    /// Identifies this window lifetime, never a persisted profile identity.
    let sessionGeneration: UUID
    private(set) var webView: WKWebView
    private let dataStore: WKWebsiteDataStore
    private let mediaPolicy: WebKitMediaPolicy
    private let window: WebKitBrowserWindow
    private let pageArea = NSView()
    private let tabStrip = NSStackView()
    private let address = NSTextField()
    private let message = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private var order: WebKitTabOrder
    private var tabs: [UUID: WebKitBrowserTab]
    private var isClosed = false
    private var closeRequested = false
    private var initialNavigationStarted = false
    private var pendingRouteActivationSession: WebKitHostIPC.Session?
    private var pendingStartupProfile: BrowserProfile?
    private var pendingRestoredSession: WebKitSessionSnapshot?
    private var commandMonitor: Any?
    private var lease: PrivateFileGuardLease?
    private var metadataLease: PrivateFileGuardLease?
    private var onClose: (() -> Void)?
    private var sessionCheckpointer: WebKitSessionCheckpointer?
    private let restoresSession: Bool
    private var assemblingSession = true
    private var checkpointWarning: String?
    private var sessionNotice: String?
    private var restoreIncomplete = false
    private var pendingSnapshot: WebKitSessionSnapshot?
    private var sessionSavePending = false
    private var downloadsSettled = false
    private var onSessionSaveError: (() -> Void)?
    private(set) var sessionWriteFailed = false
    private(set) var downloads: WebKitDownloads!
    var tabCount: Int { isClosed ? 0 : order.ids.count }
    var selectedTabID: UUID { order.selected }
    var selectedTabIndex: Int { order.ids.firstIndex(of: order.selected) ?? 0 }

    init(profile: BrowserProfile, lease: PrivateFileGuardLease, metadataLease: PrivateFileGuardLease,
         sessionGeneration: UUID = UUID(),
         downloadPicker: WebKitDownloads.Picker? = nil,
         sessionStore: WebKitSessionStore? = nil, restoredSession: WebKitSessionSnapshot? = nil,
         sessionWarning: String? = nil,
         runtime: WebKitProfileBrowserRuntime = .system,
         onSessionSaveError: (() -> Void)? = nil,
         onClose: @escaping () -> Void) throws {
        let proxyConfigurations: [Network.ProxyConfiguration]
        switch runtime {
        case .system:
            try WebKitProfilePolicy.validate(profile)
            proxyConfigurations = try WebKitProxyConfigurationFactory.systemWebKitConfigurations(for: profile.proxy)
        case .owned(let session, let relayCredential):
            try WebKitProfilePolicy.validateOwnedRuntime(profile, session: session)
            guard sessionGeneration == session.generation,
                  relayCredential.belongs(to: session) else {
                throw WebKitHostIPC.ProtocolError.invalidCapability
            }
            proxyConfigurations = [WebKitProxyConfigurationFactory.brokerConfiguration(using: relayCredential)]
        }
        if profile.startupMode == .restoreSession, sessionStore == nil { throw WebKitSessionError.unavailable }
        if let restoredSession { try restoredSession.validate(for: profile.id) }
        profileID = profile.id
        self.sessionGeneration = sessionGeneration
        mediaPolicy = profile.webKitMediaPolicy
        restoresSession = profile.startupMode == .restoreSession
        self.sessionNotice = sessionWarning; self.onSessionSaveError = onSessionSaveError
        self.lease = lease; self.metadataLease = metadataLease; self.onClose = onClose
        dataStore = WKWebsiteDataStore(forIdentifier: profile.id)
        // Apply before constructing the first view so every connection owned
        // by this persistent profile store receives the same proxy policy.
        dataStore.proxyConfigurations = proxyConfigurations
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The system engine supplies its APIs; never inject Chromium identity
        // or use the shared default website store.
        webView = WKWebView(frame: .zero, configuration: configuration)
        let first = WebKitBrowserTab(view: webView)
        tabs = [first.id: first]; order = WebKitTabOrder(first: first.id)
        window = WebKitBrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        if restoresSession, let sessionStore {
            sessionCheckpointer = WebKitSessionCheckpointer(profileID: profile.id, store: sessionStore) { [weak self] saved in
                guard let self, !self.isClosed else { return }
                self.checkpointWarning = saved ? nil : "Автосохранение вкладок не подтверждено. Проверь свободное место и доступ к папке данных NeAntik."
                self.refreshTab(self.order.selected)
            }
        }
        window.browser = self; window.delegate = self; window.isReleasedWhenClosed = false
        downloads = WebKitDownloads(window: window, picker: downloadPicker)
        window.title = "\(profile.name) — WebKit · NeAntik"
        window.minSize = NSSize(width: 640, height: 420); window.center()
        address.placeholderString = "Адрес сайта"; address.font = .systemFont(ofSize: 14)
        address.delegate = self; address.target = self; address.action = #selector(openAddress)
        address.setAccessibilityLabel("Адрес сайта")
        let bar = NSStackView(views: [button(backButton, title: "←", help: "Назад · ⌘[", action: #selector(back)),
            button(forwardButton, title: "→", help: "Вперёд · ⌘]", action: #selector(forward)),
            button(NSButton(), title: "↻", help: "Обновить · ⌘R", action: #selector(reload)), address, downloads.button])
        bar.orientation = .horizontal; bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStrip.orientation = .horizontal; tabStrip.spacing = 6; tabStrip.alignment = .centerY
        let scroll = NSScrollView()
        scroll.documentView = tabStrip; scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        let tabBar = NSStackView(views: [scroll, button(NSButton(), title: "+", help: "Новая вкладка · ⌘T", action: #selector(newTab))])
        tabBar.orientation = .horizontal; tabBar.spacing = 8
        tabBar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 6, right: 12)
        message.font = .systemFont(ofSize: 13); message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byWordWrapping; message.maximumNumberOfLines = 4
        let content = NSView(); window.contentView = content
        for view in [bar, tabBar, pageArea, message] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: bar.bottomAnchor), tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor), tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor), tabBar.heightAnchor.constraint(equalToConstant: 42),
            tabStrip.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), tabStrip.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), tabStrip.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            pageArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor), pageArea.leadingAnchor.constraint(equalTo: content.leadingAnchor), pageArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            message.topAnchor.constraint(equalTo: pageArea.bottomAnchor, constant: 6), message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), message.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6)
        ])
        configure(first); presentSelectedTab()
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleCommand(event) ? nil : event
        }
        switch runtime {
        case .system:
            startInitialNavigation(profile: profile, restoredSession: restoredSession)
            assemblingSession = false
            checkpointSession()
        case .owned(let session, _):
            pendingRouteActivationSession = session
            pendingStartupProfile = profile
            pendingRestoredSession = restoredSession
        }
    }

    /// Called only after the authenticated child gate accepted the exact
    /// routeActive frame. Initial URL and restored tabs remain idle until the
    /// manager has activated the matching broker lease.
    @discardableResult
    func activateOwnedRoute(_ permit: WebKitOwnedNavigationPermit) -> Bool {
        guard !isClosed, let expected = pendingRouteActivationSession,
              permit.authorizes(expected),
              let profile = pendingStartupProfile else { return false }
        pendingRouteActivationSession = nil
        pendingStartupProfile = nil
        let restored = pendingRestoredSession
        pendingRestoredSession = nil
        startInitialNavigation(profile: profile, restoredSession: restored)
        initialNavigationStarted = true
        assemblingSession = false
        checkpointSession()
        return true
    }

    /// The signed host calls this after constructing its WKWebView from the
    /// pinned owned runtime and broker-only persistent store, before any page
    /// is opened. This value is only a locator; the parent still attests code.
    func networkProcessOwnerForBootstrap() throws -> WebKitOwnedNetworkProcessPID.Owner {
        guard !isClosed, pendingRouteActivationSession != nil else {
            throw WebKitHostIPC.ProtocolError.invalidTransition
        }
        return try WebKitOwnedNetworkProcessPID.currentOwner(for: dataStore)
    }

    private func startInitialNavigation(profile: BrowserProfile,
                                        restoredSession: WebKitSessionSnapshot?) {
        initialNavigationStarted = true
        guard let first = tabs[order.selected] else { return }
        if restoresSession, let restoredSession {
            first.committedURL = restoredSession.urls[0]
            first.view.load(URLRequest(url: URL(string: restoredSession.urls[0])!))
            for value in restoredSession.urls.dropFirst() {
                guard let view = openTab(at: URL(string: value)!),
                      let tab = tabs.values.first(where: { $0.view === view }) else {
                    restoreIncomplete = true
                    sessionNotice = "Не все вкладки удалось открыть. Прежний список сохранён; закрой ненужные окна и открой профиль снова."
                    break
                }
                tab.committedURL = value
            }
            if order.ids.indices.contains(restoredSession.selectedIndex) {
                selectTab(order.ids[restoredSession.selectedIndex])
            }
            if !restoreIncomplete, restoredSession.unavailableCount > 0 {
                sessionNotice = "Некоторые специальные адреса нельзя восстановить. Их вкладки открыты пустыми."
            }
            presentSelectedTab()
        } else if let url = BrowserLaunchBuilder.validatedStartURL(profile.startURL) {
            first.view.load(URLRequest(url: url))
        }
    }

    private func button(_ button: NSButton, title: String, help: String, action: Selector) -> NSButton {
        button.title = title; button.bezelStyle = .rounded; button.toolTip = help
        button.setAccessibilityLabel(help); button.target = self; button.action = action
        return button
    }
    private func configure(_ tab: WebKitBrowserTab) {
        tab.view.navigationDelegate = self; tab.view.uiDelegate = self
        tab.view.allowsBackForwardNavigationGestures = true
        let title = button(tab.titleButton, title: "Новая вкладка", help: "Переключить вкладку", action: #selector(selectTabButton(_:)))
        title.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
        title.setButtonType(.pushOnPushOff)
        title.font = .systemFont(ofSize: 14); title.lineBreakMode = .byTruncatingTail
        let close = button(tab.closeButton, title: "×", help: "Закрыть вкладку", action: #selector(closeTabButton(_:)))
        close.identifier = title.identifier
        tab.row.orientation = .horizontal; tab.row.spacing = 2
        tab.row.addArrangedSubview(title); tab.row.addArrangedSubview(close)
        title.widthAnchor.constraint(equalToConstant: 170).isActive = true
        close.widthAnchor.constraint(equalToConstant: 28).isActive = true
        tabStrip.addArrangedSubview(tab.row)
        let id = tab.id
        tab.observations = [tab.view.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshTab(id); self?.checkpointSession() }
        }, tab.view.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshTab(id) }
        }, tab.view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshTab(id) }
        }, tab.view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshTab(id) }
        }]
    }
    private func presentSelectedTab() {
        guard !isClosed, let selected = tabs[order.selected] else { return }
        webView.removeFromSuperview(); webView = selected.view
        webView.translatesAutoresizingMaskIntoConstraints = false; pageArea.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: pageArea.topAnchor), webView.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor), webView.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor)
        ])
        address.stringValue = webView.url?.absoluteString ?? selected.committedURL
        message.stringValue = displayedStatus(selected.status)
        for id in order.ids { refreshTab(id) }
        tabStrip.layoutSubtreeIfNeeded()
        tabStrip.scrollToVisible(selected.row.frame)
    }
    private func refreshTab(_ id: UUID) {
        guard !isClosed, let tab = tabs[id] else { return }
        let title = tab.view.title.flatMap { $0.isEmpty ? nil : $0 } ?? (tab.view.url?.host ?? "Новая вкладка")
        tab.titleButton.title = title
        tab.titleButton.setAccessibilityLabel("Вкладка: \(title)")
        tab.titleButton.state = order.selected == id ? .on : .off
        tab.titleButton.font = order.selected == id ? .boldSystemFont(ofSize: 14) : .systemFont(ofSize: 14)
        tab.titleButton.contentTintColor = order.selected == id ? .controlAccentColor : nil
        if order.selected == id {
            if window.firstResponder !== address.currentEditor() { address.stringValue = tab.view.url?.absoluteString ?? "about:blank" }
            backButton.isEnabled = tab.view.canGoBack; forwardButton.isEnabled = tab.view.canGoForward
            message.stringValue = displayedStatus(tab.status)
        }
    }
    private func displayedStatus(_ status: String) -> String {
        ([status] + [sessionNotice, checkpointWarning].compactMap { $0 }).joined(separator: "\n")
    }
    @discardableResult private func appendTab(configuration: WKWebViewConfiguration) -> WKWebView? {
        guard !isClosed, configuration.websiteDataStore.identifier == profileID else { return nil }
        guard WebKitProfilePolicy.canOpenTab(count: order.ids.count) else {
            setStatus("В этом окне уже 32 вкладки. Закрой ненужную, чтобы открыть новую.", for: webView)
            return nil
        }
        do { try ManagerLaunchAdmission.shared.requireSafePressure() }
        catch ManagerLaunchAdmissionError.pressure {
            setStatus("Сейчас мало свободной памяти. Закрой ненужные вкладки или профили и попробуй снова.", for: webView)
            return nil
        }
        catch {
            setStatus("Приложение завершает текущую операцию. Попробуй открыть вкладку после её окончания.", for: webView)
            return nil
        }
        let tab = WebKitBrowserTab(view: WKWebView(frame: .zero, configuration: configuration))
        tabs[tab.id] = tab; order.append(tab.id); configure(tab); presentSelectedTab()
        checkpointSession()
        return tab.view
    }
    @discardableResult func openTab(at url: URL) -> WKWebView? {
        guard WebKitProfilePolicy.permits(url) else { return nil }
        let config = WKWebViewConfiguration(); config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        guard let view = appendTab(configuration: config) else { return nil }
        view.load(URLRequest(url: url)); return view
    }
    func selectTab(_ id: UUID) {
        if !isClosed, order.select(id) { presentSelectedTab(); checkpointSession() }
    }
    func closeTab(_ id: UUID) {
        guard !isClosed, let tab = tabs[id] else { return }
        if order.ids.count == 1 { close(); return }
        let wasSelected = id == order.selected
        guard order.remove(id) else { return }
        tabStrip.removeArrangedSubview(tab.row)
        tab.detach(preserveNavigationDelegate: downloads.hasReservations(for: tab.view))
        tabs.removeValue(forKey: id)
        if wasSelected { presentSelectedTab() }
        checkpointSession()
    }
    @objc private func selectTabButton(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) { selectTab(id) }
    }
    @objc private func closeTabButton(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) { closeTab(id) }
    }
    @objc private func newTab() {
        if openTab(at: URL(string: "about:blank")!) != nil { focusAddress() }
    }
    func show() { guard !isClosed, initialNavigationStarted else { return }; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    /// Manager Stop closes the entire profile, whereas Command-W closes a tab.
    func close() {
        if !isClosed {
            guard !closeRequested else { return }
            closeRequested = true
            // AppKit ignores performClose while NSSavePanel owns a sheet.
            // Cancel our producers/panel first, then close after real settlement.
            downloads.close { [weak self] in
                guard let self, !self.isClosed else { return }
                self.window.performClose(nil)
            }
        } else if sessionWriteFailed, let pendingSnapshot { beginSessionSave(pendingSnapshot) }
    }
    func focusAddress() { if !isClosed { window.makeFirstResponder(address); address.selectText(nil) } }
    fileprivate func handleCommand(_ event: NSEvent) -> Bool {
        guard !isClosed, let command = WebKitWindowCommand.resolve(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
        switch command {
        case .address: focusAddress()
        case .reload: reload()
        case .close: closeTab(order.selected)
        case .back: back()
        case .forward: forward()
        case .newTab: newTab()
        case .previousTab: order.cycle(-1); presentSelectedTab(); checkpointSession()
        case .nextTab: order.cycle(1); presentSelectedTab(); checkpointSession()
        }
        return true
    }
    @objc func back() { if !isClosed { webView.goBack() } }
    @objc func forward() { if !isClosed { webView.goForward() } }
    @objc func reload() { if !isClosed { webView.reload() } }
    @objc private func openAddress() {
        guard !isClosed, let url = BrowserLaunchBuilder.validatedStartURL(address.stringValue), WebKitProfilePolicy.permits(url) else {
            message.stringValue = "Введи адрес http:// или https://. Для пустой страницы — about:blank."; return
        }
        webView.load(URLRequest(url: url)); window.makeFirstResponder(webView)
    }
    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }; isClosed = true
        if restoresSession, initialNavigationStarted, !restoreIncomplete {
            do {
                beginSessionSave(try captureSession())
            } catch { sessionWriteFailed = true; onSessionSaveError?() }
        }
        if let commandMonitor { NSEvent.removeMonitor(commandMonitor); self.commandMonitor = nil }
        let closingViews = tabs.values.map(\.view)
        for tab in tabs.values { tab.detach(preserveNavigationDelegate: downloads.hasReservations(for: tab.view)) }; tabs.removeAll()
        window.contentView = nil; window.delegate = nil; window.browser = nil
        downloads.close { [self, closingViews] in
            for view in closingViews { view.navigationDelegate = nil }
            downloadsSettled = true
            finishCloseIfSettled()
        }
    }
    private func captureSession() throws -> WebKitSessionSnapshot {
        // Committed history includes pushState/fragments but never a new
        // provisional request. The same rule applies to autosave and close.
        try WebKitSessionSnapshot.capture(profileID: profileID,
            urls: order.ids.map { tabs[$0]?.view.backForwardList.currentItem?.url.absoluteString ?? tabs[$0]?.committedURL ?? "about:blank" },
            selectedIndex: order.ids.firstIndex(of: order.selected) ?? 0)
    }
    private func checkpointSession() {
        guard restoresSession, initialNavigationStarted, !assemblingSession, !restoreIncomplete, !isClosed else { return }
        do { sessionCheckpointer?.schedule(try captureSession()) }
        catch {
            checkpointWarning = "Список вкладок не удалось подготовить к сохранению. Последняя сохранённая сессия не изменена."
            refreshTab(order.selected)
        }
    }
    private func beginSessionSave(_ snapshot: WebKitSessionSnapshot) {
        guard let sessionCheckpointer, !sessionSavePending else { return }
        pendingSnapshot = snapshot; sessionSavePending = true; sessionWriteFailed = false
        Task { [self] in
            let saved = await sessionCheckpointer.finish(snapshot)
            sessionSavePending = false
            if saved { pendingSnapshot = nil }
            else { sessionWriteFailed = true; onSessionSaveError?() }
            finishCloseIfSettled()
        }
    }
    private func finishCloseIfSettled() {
        guard downloadsSettled, !sessionSavePending, !sessionWriteFailed else { return }
        let callback = onClose; onClose = nil; onSessionSaveError = nil
        metadataLease?.release(); metadataLease = nil; lease?.release(); lease = nil
        callback?()
    }
    private func owns(_ view: WKWebView) -> Bool { !isClosed && tabs.values.contains { $0.view === view } }
    private func setStatus(_ value: String, for view: WKWebView) {
        guard !isClosed, let tab = tabs.values.first(where: { $0.view === view }) else { return }
        tab.status = value; refreshTab(tab.id)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if owns(webView), action.shouldPerformDownload, let url = action.request.url,
           WebKitProfilePolicy.permits(url) || url.scheme?.lowercased() == "blob" {
            let admitted = downloads.reserve(action, from: webView)
            decisionHandler(admitted ? .download : .cancel)
            if admitted { downloads.policyAccepted() }
            return
        }
        guard owns(webView), let url = action.request.url, WebKitProfilePolicy.permits(url) else {
            setStatus("Этот тип ссылки пока не поддерживается в WebKit-профиле.", for: webView)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard owns(webView) else { decisionHandler(.cancel); return }
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased().hasPrefix("attachment") == true
        if !response.canShowMIMEType || attachment {
            let admitted = downloads.reserve(response, from: webView)
            decisionHandler(admitted ? .download : .cancel)
            if admitted { downloads.policyAccepted() }
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.adopt(download, token: navigationAction, allowed: owns(webView))
        if !owns(webView), !downloads.hasReservations(for: webView) { webView.stopLoading(); webView.navigationDelegate = nil }
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.adopt(download, token: navigationResponse, allowed: owns(webView))
        if !owns(webView), !downloads.hasReservations(for: webView) { webView.stopLoading(); webView.navigationDelegate = nil }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard WebKitProfilePolicy.permitsPopup(profileID: profileID, openerIsOwned: owns(webView),
            storeID: configuration.websiteDataStore.identifier, persistent: configuration.websiteDataStore.isPersistent,
            url: action.request.url) else { return nil }
        // WebKit supplies this configuration to preserve opener semantics.
        // Return the owned view; WebKit performs navigation itself.
        return appendTab(configuration: configuration)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let knownType: Bool
        switch type { case .camera, .microphone, .cameraAndMicrophone: knownType = true; @unknown default: knownType = false }
        // Do not grant or cache consent. WebKit still enforces frame/Permissions
        // Policy, secure-context requirements and the system hardware prompt.
        decisionHandler(mediaPolicy.decision(owned: owns(webView) && frame.webView === webView,
            persistent: webView.configuration.websiteDataStore.isPersistent,
            storeID: webView.configuration.websiteDataStore.identifier, profileID: profileID,
            secureOrigin: WebKitMediaPolicy.permitsOrigin(scheme: origin.protocol, host: origin.host),
            knownCaptureType: knownType))
    }
    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tabs.values.first(where: { $0.view === webView }) { closeTab(tab.id) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setStatus("WebKit · данные этого профиля · параметры устройства определяет macOS", for: webView)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard owns(webView), let tab = tabs.values.first(where: { $0.view === webView }), let value = webView.url?.absoluteString else { return }
        tab.committedURL = value
        checkpointSession()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    private func navigationFailed(_ view: WKWebView, _ error: Error) {
        // Cancellation is normal when a navigation is replaced. Never show
        // NSError userInfo/URL: it may contain credentials or private data.
        // WebKit ends NAVIGATION with legacy policy error102 when converting
        // to a download. It does not settle that download or its reservation.
        let native = error as NSError
        if native.domain == "WebKitErrorDomain", native.code == 102 { return }
        // Other navigation/iframe failures cannot identify which pending
        // download converted; only didBecome consumes its exact token.
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        setStatus("Не удалось открыть страницу. Проверь адрес и подключение к сети; затем обнови страницу.", for: view)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setStatus("Процесс страницы завершился. Нажми «Обновить», чтобы открыть её снова.", for: webView)
    }
}
