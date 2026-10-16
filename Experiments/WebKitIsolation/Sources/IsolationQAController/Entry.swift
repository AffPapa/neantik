import AppKit
import SystemExtensions
@preconcurrency import NetworkExtension
import Security
import CryptoKit
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
    private let filterPorts = NSTextField()
    private var includesLoopbackFilter: Bool { Bundle.main.object(forInfoDictionaryKey: "NeAntikQALoopbackFilterIncluded") as? Bool == true }
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
        let w = NSWindow(contentRect: .init(x:0,y:0,width:720,height:740), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        w.title = "NeAntik · Kernel isolation QA · не рабочий браузер"
        let title = NSTextField(labelWithString: "Новый системный механизм, не повтор HTTP/SOCKS")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        filterPorts.placeholderString = "Только порты собственных loopback QA серверов, через запятую"
        let stack = NSStackView(views:[title,status,
            button("1. Запросить установку только QA system extension",#selector(activateExtension)),
            button("2. Сохранить правило только для QA Host A",#selector(configureRule)),
            button("3. Включить deny-only provider",#selector(startProvider)),
            button("Открыть A — перехватываемый QA Host",#selector(openA)),
            button("Открыть B — независимый Direct-контроль",#selector(openB)),
            button("Прочитать обезличенные счётчики provider",#selector(readCounters)),
            button("Остановить provider, сохранив app rule",#selector(stopProvider)),
            button("Закрыть только запущенные этим окном QA Hosts",#selector(closeOwnedHosts)),
            filterPorts,
            button("QA: включить отдельный фильтр только своих loopback портов",#selector(configureLoopbackFilter)),
            button("QA: удалить только свой loopback filter",#selector(removeLoopbackFilter)),
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
    private func hostPin(control: Bool = false) throws -> (SignedHostPin,String) {
        let identifier = control ? appID + ".control" : hostID
        let url = helpers.appendingPathComponent(control ? "NeAntik Isolation Control.app" : "NeAntik Isolation Host.app")
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL,SecCSFlags(),&code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info) == errSecSuccess,
              let fields = info as? [String:Any], fields[kSecCodeInfoIdentifier as String] as? String == identifier,
              fields[kSecCodeInfoTeamIdentifier as String] as? String == "H6VGU2M6JD",
              let hash = fields[kSecCodeInfoUnique as String] as? Data, hash.count == 20,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),nil) == errSecSuccess
        else { throw NSError(domain:"app.neantik.isolation.qa",code:1) }
        return (try SignedHostPin(identifier:identifier,team:"H6VGU2M6JD",cdHash:hash),hash.map{String(format:"%02x",$0)}.joined())
    }

    @objc private func configureLoopbackFilter() { changeLoopbackFilter(enable: true) }
    @objc private func removeLoopbackFilter() { changeLoopbackFilter(enable: false) }
    private func changeLoopbackFilter(enable: Bool) {
        guard includesLoopbackFilter else { status.stringValue = "Нужен отдельно разрешённый opt-in QA build с content-filter capability. Ничего не меняю."; return }
        guard let ticket = begin(.configuration) else { return }
        guard hostsAbsent,
              let (_,hostHash) = try? hostPin(), let (_,controlHash) = try? hostPin(control: true), hostHash != controlHash,
              let run = Bundle.main.object(forInfoDictionaryKey: "NeAntikQARunID") as? String, UUID(uuidString: run) != nil
        else { status.stringValue = "Нужны закрытые отдельные подписанные A/B. Ничего не сохранено."; finish(ticket); return }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil, self.hostsAbsent else { self.status.stringValue = "Не удалось прочитать QA filter или окна ещё открыты."; self.finish(ticket); return }
                if let existing = manager.providerConfiguration {
                    // Never overwrite another app's filter, a previous run or
                    // a configuration with broader/unrecognised capabilities.
                    guard existing.filterDataProviderBundleIdentifier == self.extensionID,
                          existing.filterPacketProviderBundleIdentifier == nil,
                          existing.filterSockets, !existing.filterPackets,
                          let vendor = existing.vendorConfiguration,
                          Set(vendor.keys) == ["runID", "ports", "hostCDHash", "controlCDHash"],
                          vendor["runID"] as? String == run,
                          vendor["hostCDHash"] as? String == hostHash,
                          vendor["controlCDHash"] as? String == controlHash,
                          let ports = vendor["ports"] as? [Int], ports.allSatisfy({ (1...65535).contains($0) }),
                          (try? QALoopbackFilterScope(ports: ports.map(UInt16.init))) != nil
                    else { self.status.stringValue = "Filter не принадлежит этому QA run или scope отличается; ничего не меняю."; self.finish(ticket); return }
                    // An existing run must be removed explicitly before changing
                    // ports. No silent overwrite or reset of another policy.
                    guard !enable else { self.status.stringValue = "Сначала явно удалите свой текущий QA filter."; self.finish(ticket); return }
                } else if !enable {
                    self.status.stringValue = "Своего QA filter нет; удалять нечего."; self.finish(ticket); return
                }
                let completion: @Sendable (Error?) -> Void = { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        guard error == nil else { self.status.stringValue = "macOS отказала в изменении QA filter. Это setup failure."; self.finish(ticket); return }
                        manager.loadFromPreferences { [weak self] readError in
                            Task { @MainActor in
                                guard let self else { return }
                                let scoped = enable ? self.matchesOwnedFilter(manager, run: run, hostHash: hostHash, controlHash: controlHash) : manager.providerConfiguration == nil
                                self.status.stringValue = readError == nil && scoped ? "Точный QA scope перечитан. Успешный apply и маршрут требуют отдельных наблюдений; это не PASS." : "QA filter не подтверждён после записи/удаления. Окна A не открывать."
                                self.pendingFilterPorts = nil
                                self.finish(ticket)
                            }
                        }
                    }
                }
                guard self.hostsAbsent else { self.finish(ticket); return }
                if enable {
                    let text = self.filterPorts.stringValue.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    let ports = text.compactMap(UInt16.init)
                    guard ports.count == text.count, let scope = try? QALoopbackFilterScope(ports: ports) else {
                        self.status.stringValue = "Укажите 1–4 разных собственных порта от 1 до 65535."; self.finish(ticket); return
                    }
                    // A typed port is not proof of ownership. The separately
                    // launched own fixture must still hold both loopback
                    // listeners and prove a per-run, never-persisted key.
                    guard await self.proveOwnListeners(ports: scope.ports, run: run), self.hostsAbsent else {
                        self.status.stringValue = "Нет подтверждения собственных IPv4/IPv6 listeners текущего run. Ничего не сохранено."; self.finish(ticket); return
                    }
                    let config = NEFilterProviderConfiguration()
                    config.filterSockets = true; config.filterPackets = false
                    config.filterDataProviderBundleIdentifier = self.extensionID
                    config.vendorConfiguration = ["runID": run, "ports": scope.ports.map(Int.init), "hostCDHash": hostHash, "controlCDHash": controlHash]
                    manager.providerConfiguration = config
                    manager.localizedDescription = "NeAntik owned loopback filter QA"
                    manager.isEnabled = true
                    self.pendingFilterPorts = scope.ports.map(Int.init)
                    manager.saveToPreferences(completionHandler: completion)
                } else {
                    manager.removeFromPreferences(completionHandler: completion)
                }
            }
        }
    }

    private var pendingFilterPorts: [Int]?
    private func matchesOwnedFilter(_ manager: NEFilterManager, run: String, hostHash: String, controlHash: String) -> Bool {
        guard manager.isEnabled, let config = manager.providerConfiguration,
              config.filterDataProviderBundleIdentifier == extensionID,
              config.filterPacketProviderBundleIdentifier == nil,
              config.filterSockets, !config.filterPackets,
              let vendor = config.vendorConfiguration,
              Set(vendor.keys) == ["runID", "ports", "hostCDHash", "controlCDHash"],
              vendor["runID"] as? String == run,
              vendor["hostCDHash"] as? String == hostHash,
              vendor["controlCDHash"] as? String == controlHash,
              let expectedPorts = pendingFilterPorts,
              vendor["ports"] as? [Int] == expectedPorts else { return false }
        return true
    }
    private func proveOwnListeners(ports: [UInt16], run: String) async -> Bool {
        guard let text = ProcessInfo.processInfo.environment["NEANTIK_OWNED_QA_ORIGIN_LEASE"], text.utf8.count <= 2048,
              let bytes = text.data(using: .utf8), let lease = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              Set(lease.keys) == ["runID", "ports", "key"], lease["runID"] as? String == run,
              lease["ports"] as? [Int] == ports.map(Int.init),
              let hex = lease["key"] as? String, hex.utf8.count == 64,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        let key = Data(stride(from: 0, to: 64, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)
        })
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: QANoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for port in ports {
            for host in ["127.0.0.1", "[::1]"] {
                let challenge = UUID().uuidString.lowercased()
                let message = Data("\(run)\n\(challenge)\n\(port)".utf8)
                guard let url = URL(string: "http://\(host):\(port)/__neantik_isolation_qa/\(run)/__proof") else { return false }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
                request.setValue(challenge, forHTTPHeaderField: "X-NeAntik-QA-Challenge")
                do {
                    let (data, response) = try await session.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 256,
                          let body = try JSONSerialization.jsonObject(with: data) as? [String: String], Set(body.keys) == ["proof"],
                          let proof = body["proof"], proof.utf8.count == 64,
                          proof == HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)).map({ String(format: "%02x", $0) }).joined()
                    else { return false }
                } catch { return false } // No URL/error payload is logged.
            }
        }
        return true
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
        guard includesLoopbackFilter else { deactivateAfterFilterCheck(ticket); return }
        let filter = NEFilterManager.shared()
        filter.loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil, self.hostsAbsent,
                      filter.providerConfiguration?.filterDataProviderBundleIdentifier != self.extensionID else {
                    self.status.stringValue = "Сначала удалите свой QA filter; extension пока не удаляется."; self.finish(ticket); return
                }
                self.deactivateAfterFilterCheck(ticket)
            }
        }
    }
    private func deactivateAfterFilterCheck(_ ticket: QAOperationFence.Ticket) {
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
    nonisolated func request(_ request:OSSystemExtensionRequest,actionForReplacingExtension existing:OSSystemExtensionProperties,withExtension ext:OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Optional, signed recipe for precisely the retained inactive QA3.
        // Default builds still cancel. No production/active/unknown extension
        // may be replaced, even if it has a matching team or identifier.
        let bundle = Bundle.main
        guard bundle.object(forInfoDictionaryKey: "NeAntikQALoopbackFilterIncluded") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "NeAntikQAReplacementFromBuild") as? String == "3",
              let hash = bundle.object(forInfoDictionaryKey: "NeAntikQAPreviousProviderCDHash") as? String,
              hash.utf8.count == 40, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              existing.bundleIdentifier == "app.neantik.desktop.network-qa.proxy",
              ext.bundleIdentifier == existing.bundleIdentifier,
              existing.bundleVersion == "3", ext.bundleVersion == "5",
              !existing.isEnabled, !existing.isAwaitingUserApproval, !existing.isUninstalling,
              ext.url.standardizedFileURL == bundle.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/app.neantik.desktop.network-qa.proxy.systemextension").standardizedFileURL
        else { return .cancel }
        let expression = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"H6VGU2M6JD\" and identifier \"app.neantik.desktop.network-qa.proxy\" and cdhash H\"\(hash)\""
        var requirement: SecRequirement?, code: SecStaticCode?
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(existing.url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { return .cancel }
        return .replace // OS authorization/validation still applies.
    }
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
private final class QANoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
@main enum Main {
    @MainActor static func main() {
        guard Bundle.main.bundleIdentifier == "app.neantik.desktop.network-qa" else { exit(78) }
        let app = NSApplication.shared,delegate = Controller(); app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
