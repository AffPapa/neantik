import AppKit
import SystemExtensions
@preconcurrency import NetworkExtension
import Security
import IsolationNetworkExtension
import IsolationCore
import Darwin

@MainActor private final class Controller: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private let appID = "app.neantik.desktop.network-qa"
    private let extensionID = "app.neantik.desktop.network-qa.proxy"
    private let hostID = "app.neantik.desktop.network-qa.profilehost"
    private var window: NSWindow?
    private var manager: NEAppProxyProviderManager?
    private var ownApps: [NSRunningApplication] = []
    private var operation = QAOperationFence()
    private var controls: [NSButton] = []
    private var extensionOperation: (OSSystemExtensionRequest, QAOperationFence.Ticket)?
    private var extensionAction = "Установка"
    private func begin(_ kind: QAOperationFence.Kind) -> QAOperationFence.Ticket? {
        guard let ticket = operation.begin(kind) else { status.stringValue = "Дождитесь завершения текущего QA-действия."; return nil }
        controls.forEach { $0.isEnabled = false }; return ticket
    }
    private func finish(_ ticket: QAOperationFence.Ticket) {
        if operation.finish(ticket) { controls.forEach { $0.isEnabled = true } }
    }
    private var hostsAbsent: Bool {
        operation.pendingLaunches == 0 && ownApps.allSatisfy(\.isTerminated) &&
        [hostID, appID + ".control"].allSatisfy { NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }
    private let status = NSTextField(wrappingLabelWithString: "Только отдельные QA-приложения. Ничего не устанавливается и не включается при запуске.")
    private var helpers: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action); controls.append(value); return value
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier == appID else { NSApp.terminate(nil); return }
        let w = NSWindow(contentRect: .init(x:0,y:0,width:720,height:600), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        w.title = "NeAntik · Kernel isolation QA · не рабочий браузер"
        let title = NSTextField(labelWithString: "Новый системный механизм, не повтор HTTP/SOCKS")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let stack = NSStackView(views:[title,status,
            button("1. Запросить установку только QA system extension",#selector(activateExtension)),
            button("2. Сохранить правило только для QA Host A",#selector(configureRule)),
            button("3. Включить deny-only provider",#selector(startProvider)),
            button("Открыть A — перехватываемый QA Host",#selector(openA)),
            button("Открыть B — независимый Direct-контроль",#selector(openB)),
            button("Прочитать обезличенные счётчики provider",#selector(readCounters)),
            button("Остановить provider, сохранив app rule",#selector(stopProvider)),
            button("Закрыть только запущенные этим окном QA Hosts",#selector(closeOwnedHosts)),
            button("Удалить только QA-конфигурацию после выхода Hosts",#selector(removeConfiguration)),
            button("Запросить удаление только QA system extension",#selector(deactivateExtension))])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:w.contentView!.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:w.contentView!.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:w.contentView!.topAnchor,constant:20),stack.bottomAnchor.constraint(lessThanOrEqualTo:w.contentView!.bottomAnchor,constant:-20)])
        window = w; w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    @objc private func activateExtension() {
        // This button is for a separately authorized installed QA stage only.
        // It is never called automatically by preparation/build or app launch.
        guard let ticket = begin(.extensionRequest) else { return }
        guard hostsAbsent else { status.stringValue = "Сначала завершите QA Hosts."; finish(ticket); return }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:extensionID,queue:.main)
        extensionAction = "Установка"
        extensionOperation = (request,ticket)
        request.delegate = self; OSSystemExtensionManager.shared.submitRequest(request)
        self.status.stringValue = "Запрошена установка QA extension; macOS может потребовать отдельное подтверждение."
    }
    private func hostPin() throws -> (SignedHostPin,String) {
        let url = helpers.appendingPathComponent("NeAntik Isolation Host.app")
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL,SecCSFlags(),&code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info) == errSecSuccess,
              let fields = info as? [String:Any], fields[kSecCodeInfoIdentifier as String] as? String == hostID,
              fields[kSecCodeInfoTeamIdentifier as String] as? String == "H6VGU2M6JD",
              let hash = fields[kSecCodeInfoUnique as String] as? Data, hash.count == 20,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),nil) == errSecSuccess
        else { throw NSError(domain:"app.neantik.isolation.qa",code:1) }
        return (try SignedHostPin(identifier:hostID,team:"H6VGU2M6JD",cdHash:hash),hash.map{String(format:"%02x",$0)}.joined())
    }
    private func loadManager(_ completion: @escaping (NEAppProxyProviderManager?) -> Void) {
        NEAppProxyProviderManager.loadAllFromPreferences { [weak self] values,error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else { self.status.stringValue = "macOS не разрешила чтение QA-конфигурации. Это setup failure, не PASS."; completion(nil); return }
                let matching = (values ?? []).filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID }
                guard matching.count <= 1 else { self.status.stringValue = "Найден конфликт QA-конфигураций; ничего не меняю."; completion(nil); return }
                completion(matching.first ?? NEAppProxyProviderManager())
            }
        }
    }
    @objc private func configureRule() {
        guard let ticket = begin(.configuration) else { return }
        guard hostsAbsent,
              let (pin,hash) = try? hostPin(),
              let run = Bundle.main.object(forInfoDictionaryKey:"NeAntikQARunID") as? String,
              UUID(uuidString:run) != nil else { self.status.stringValue = "Нужны подписанный собственный Host и закрытые окна A. Ничего не сохранено."; finish(ticket); return }
        loadManager { [weak self] selected in
            guard let self else { return }
            guard let selected, self.hostsAbsent else { self.finish(ticket); return }
            guard selected.routingMethod == .sourceApplication else {
                self.status.stringValue = "macOS не создала source-application scope. Ничего не сохраняется: глобальный VPN недопустим."; self.finish(ticket); return
            }
            let config = NETunnelProviderProtocol(); config.providerBundleIdentifier = extensionID
            config.includeAllNetworks = false
            config.serverAddress = "NeAntik owned isolation QA"
            config.providerConfiguration = ["runID":run,"hostCDHash":hash]
            selected.protocolConfiguration = config; selected.localizedDescription = "NeAntik owned WebKit isolation QA"
            selected.appRules = [pin.dedicatedHostRule()]
            selected.safariDomains = []; selected.mailDomains = []; selected.calendarDomains = []; selected.contactsDomains = []
            selected.excludedDomains = []; selected.associatedDomains = []
            selected.isEnabled = true; selected.isOnDemandEnabled = false
            // No event-loop turn occurs between this check and the mutation;
            // pending launches hold the same fence until NSWorkspace completes.
            guard self.hostsAbsent else { self.finish(ticket); return }
            selected.saveToPreferences { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    guard error == nil else { self.status.stringValue = "macOS отказала в QA app rule. Это setup failure; Direct не объявлен защищённым."; self.finish(ticket); return }
                    selected.loadFromPreferences { [weak self] error in
                        Task { @MainActor in
                            guard let self else { return }; defer { self.finish(ticket) }; self.manager = error == nil && self.isScoped(selected) ? selected : nil
                            self.status.stringValue = self.manager != nil ? "Сохранено только правило QA Host A. Маршрут ещё не доказан; provider не запущен автоматически." : "Не удалось перечитать правило; проверка не пройдена."
                        }
                    }
                }
            }
        }
    }
    private func isScoped(_ value: NEAppProxyProviderManager) -> Bool {
        guard value.routingMethod == .sourceApplication,
              let config = value.protocolConfiguration as? NETunnelProviderProtocol,
              config.providerBundleIdentifier == extensionID, !config.includeAllNetworks,
              value.appRules.count == 1, let rule = value.appRules.first,
              let (pin,hash) = try? hostPin(),
              rule.matchSigningIdentifier == hostID,
              rule.matchDesignatedRequirement == pin.dedicatedHostRule().matchDesignatedRequirement,
              (rule.matchDomains?.isEmpty ?? true), (rule.matchTools?.isEmpty ?? true),
              value.safariDomains.isEmpty, value.mailDomains.isEmpty,
              value.calendarDomains.isEmpty, value.contactsDomains.isEmpty,
              value.excludedDomains.isEmpty, value.associatedDomains.isEmpty,
              !value.isOnDemandEnabled, value.isEnabled,
              config.providerConfiguration?["hostCDHash"] as? String == hash,
              config.providerConfiguration?["runID"] as? String == Bundle.main.object(forInfoDictionaryKey:"NeAntikQARunID") as? String else { return false }
        return true
    }
    @objc private func startProvider() {
        guard let ticket = begin(.providerControl) else { return }; defer { finish(ticket) }
        guard let manager, isScoped(manager) else { self.status.stringValue = "Нужна перечитанная конфигурация только QA Host A, без глобального routing."; return }
        do { try manager.connection.startVPNTunnel(); self.status.stringValue = "Старт запрошен. Нужны фактические счётчики и origin-контроли; это ещё не PASS." }
        catch { self.status.stringValue = "Provider не запущен. Нужны правильные provisioning/signing/install permissions; это setup failure." }
    }
    private func launch(_ name:String) {
        guard let ticket = begin(.launchHost) else { return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at:helpers.appendingPathComponent(name),configuration:configuration) { [weak self] app,error in
            Task { @MainActor in
                guard let self else { return }
                defer { self.finish(ticket) }
                if error == nil, let app { self.ownApps.append(app); self.status.stringValue = "Запущен отдельный временный QA Host. URL нужно указать явно." }
                else { self.status.stringValue = "QA Host не запущен; это не результат сетевой проверки." }
            }
        }
    }
    @objc private func openA() { launch("NeAntik Isolation Host.app") }
    @objc private func openB() { launch("NeAntik Isolation Control.app") }
    @objc private func stopProvider() {
        guard let ticket = begin(.providerControl) else { return }; defer { finish(ticket) }
        manager?.connection.stopVPNTunnel(); self.status.stringValue = "Запрошена остановка provider. App rule остаётся: отсутствие Direct нужно измерить отдельно."
    }
    @objc private func readCounters() {
        // Observation must not hold the mutation fence: a dead provider may
        // never reply. Cleanup remains available; late replies cannot restore
        // old state or report counters from a removed configuration.
        guard !operation.isBusy else { return }
        guard let observed = manager, let session = observed.connection as? NETunnelProviderSession else { self.status.stringValue = "Нет собственной provider session."; return }
        do {
            try session.sendProviderMessage(Data("owned-qa-counters-v1".utf8)) { [weak self] data in
                Task { @MainActor in
                    guard let self, !self.operation.isBusy, self.manager === observed else { return }
                    guard let data, let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                          let tcp = value["tcp"] as? Int, let udp = value["udp"] as? Int,
                          let known = value["matchingHost"] as? Int, let unknown = value["unknownHost"] as? Int,
                          QAObservationIdentity.matches(actual: value["runID"] as? String,
                              expected: Bundle.main.object(forInfoDictionaryKey:"NeAntikQARunID") as? String)
                    else { self.status.stringValue = "Счётчики не получены; не PASS."; return }
                    self.status.stringValue = "Получено provider: TCP \(tcp), UDP \(udp), Host match \(known), unknown \(unknown). Origin и B проверяются отдельно."
                }
            }
        } catch { self.status.stringValue = "Не удалось прочитать QA-счётчики; не PASS." }
    }
    @objc private func closeOwnedHosts() {
        guard let ticket = begin(.closeHosts) else { return }; defer { finish(ticket) }
        for app in ownApps where !app.isTerminated {
            guard app.bundleURL?.deletingLastPathComponent().standardizedFileURL == helpers.standardizedFileURL,
                  [hostID,appID+".control"].contains(app.bundleIdentifier ?? "") else { continue }
            _ = app.terminate()
        }
        self.status.stringValue = "Запрошен штатный выход только своих Hosts. До удаления правил отдельно проверяется фактический выход."
    }
    @objc private func removeConfiguration() {
        guard let ticket = begin(.configuration) else { return }
        guard hostsAbsent else { status.stringValue = "Сначала завершите QA Hosts. Правило активного Host не удаляется."; finish(ticket); return }
        // Reload immediately before mutation: cached preferences are not authority.
        loadManager { [weak self] value in
            guard let self else { return }
            guard self.hostsAbsent else { self.status.stringValue = "QA Hosts ещё активны; ничего не удалено."; self.finish(ticket); return }
            guard let value else { self.status.stringValue = "QA-конфигурация не прочитана; ничего не удалено."; self.finish(ticket); return }
            guard self.isScoped(value) else {
                // Retain the refusal. These flags diagnose preference changes
                // without dumping endpoints, requirements or stored config.
                self.status.stringValue = "Контракт QA-конфигурации изменился; ничего не удалено. Enabled: \(value.isEnabled), on-demand: \(value.isOnDemandEnabled), app rules: \(value.appRules.count)."
                self.finish(ticket); return
            }
            value.connection.stopVPNTunnel()
            value.removeFromPreferences { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }; defer { self.finish(ticket) }
                    if error == nil { self.manager = nil }
                    self.status.stringValue = error == nil ? "Собственная QA-конфигурация удалена; system extension отдельно остаётся установленной." : "Не удалось удалить QA-конфигурацию; нужна явная cleanup-проверка."
                }
            }
        }
    }
    @objc private func deactivateExtension() {
        guard let ticket = begin(.extensionRequest) else { return }
        guard hostsAbsent else { status.stringValue = "Сначала завершите собственные QA Hosts."; finish(ticket); return }
        NEAppProxyProviderManager.loadAllFromPreferences { [weak self] values,error in
            Task { @MainActor in
                guard let self else { return }
                guard self.hostsAbsent, error == nil, !(values ?? []).contains(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID }) else {
                    self.status.stringValue = "Сначала завершите QA Hosts и удалите собственную QA-конфигурацию; extension пока не удаляется."; self.finish(ticket); return
                }
                let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier:self.extensionID,queue:.main)
                self.extensionAction = "Удаление"
                self.extensionOperation = (request,ticket)
                request.delegate = self; OSSystemExtensionManager.shared.submitRequest(request)
                self.status.stringValue = "Запрошено удаление только QA extension; завершение требует проверки macOS."
            }
        }
    }
    private func finishExtension(_ request: OSSystemExtensionRequest, message: String) {
        guard let (pending,ticket) = extensionOperation, pending === request else { return }
        extensionOperation = nil; status.stringValue = message; finish(ticket)
    }
    nonisolated func requestNeedsUserApproval(_ request:OSSystemExtensionRequest) {
        Task { @MainActor [weak self] in self?.status.stringValue = "macOS просит разрешить только QA system extension в настройках. Защита системы не отключается." }
    }
    nonisolated func request(_ request:OSSystemExtensionRequest,actionForReplacingExtension existing:OSSystemExtensionProperties,withExtension ext:OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .cancel }
    nonisolated func request(_ request:OSSystemExtensionRequest,didFinishWithResult result:OSSystemExtensionRequest.Result) {
        Task { @MainActor [weak self] in self?.finishExtension(request, message: "Запрос system extension завершён. Его результат и действующие правила проверяются отдельно.") }
    }
    nonisolated func request(_ request:OSSystemExtensionRequest,didFailWithError error:Error) {
        let code = (error as NSError).code
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.finishExtension(request, message: "\(self.extensionAction) QA extension: macOS отказала, код \(code). Защита не обходится; это setup failure.")
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { !operation.isBusy && hostsAbsent }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !operation.isBusy, hostsAbsent else { status.stringValue = "Дождитесь QA-действия и завершите свои Hosts перед выходом."; window?.makeKeyAndOrderFront(nil); return .terminateCancel }
        return .terminateNow
    }
}
@main enum Main {
    @MainActor static func main() {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.network-qa" else { exit(78) }
        let app = NSApplication.shared,delegate = Controller(); app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
