import SwiftUI

/// Deliberately local result lifetime: editing the endpoint or proxy cancels
/// the request. No custom observation is written into automatic proxy health.
struct ProxyDiagnosticSheet: View {
    let configuration: ProxyConfiguration
    let contextRevision: String
    let paths: AppPaths
    let readPassword: @Sendable () async throws -> String
    let snapshotIsCurrent: @MainActor () async throws -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var preference: ProxyDiagnosticPreference?
    @State private var consent = false
    @State private var loaded = false
    @State private var isSaving = false
    @State private var message: String?
    @State private var requestID = UUID()
    @State private var task: Task<Void, Never>?
    @State private var observation: ProxyDiagnosticObservation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(NSLocalizedString("page.242", tableName: "Pages", bundle: .main, value: "Свой адрес диагностики", comment: ""), systemImage: "network")
                .font(.title2.bold())
            Text(NSLocalizedString("page.243", tableName: "Pages", bundle: .main, value: "Ручной запрос через выбранный прокси. Адрес сохранится для следующих проверок, но вставка и сохранение не отправляют запрос.", comment: ""))
                .foregroundStyle(.secondary)
            TextField("https://your-domain.example/ip", text: $address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(NSLocalizedString("page.244", tableName: "Pages", bundle: .main, value: "HTTPS-адрес диагностики прокси", comment: ""))
                .disabled(!loaded || isSaving)
            Text(NSLocalizedString("page.245", tableName: "Pages", bundle: .main, value: "Ответ: JSON с полем ip — IPv4 или IPv6. Без переадресаций, query и fragment. Другие поля не меняют язык, часовой пояс или настройки профиля.", comment: ""))
                .font(.callout).foregroundStyle(.secondary)
            Toggle(NSLocalizedString("page.246", tableName: "Pages", bundle: .main, value: "Разрешаю запрос этому сервису через настроенный прокси", comment: ""), isOn: $consent)
                .disabled(isSaving)
            if let observation {
                Label(String(format: NSLocalizedString("page.247", tableName: "Pages", bundle: .main, value: "Сервис доступен через прокси · %@ мс", comment: ""), String(describing: observation.responseTimeMilliseconds)), systemImage: "checkmark.circle")
                Text(String(format: NSLocalizedString("page.248", tableName: "Pages", bundle: .main, value: "Заявленный сервисом IP: %@", comment: ""), String(describing: observation.ipAddress)))
                    .textSelection(.enabled)
                Text(NSLocalizedString("page.249", tableName: "Pages", bundle: .main, value: "Это результат curl на момент проверки. Маршрут Chromium не измерен; GeoIP и подготовка запуска проверяются отдельно.", comment: ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(NSLocalizedString("page.250", tableName: "Pages", bundle: .main, value: "Сохранить адрес", comment: "")) { save() }
                    .disabled(!loaded || task != nil || validatedEndpoint == nil)
                Spacer()
                if task != nil {
                    ProgressView().controlSize(.small)
                    if isSaving { Text(NSLocalizedString("page.251", tableName: "Pages", bundle: .main, value: "Сохраняем адрес…", comment: "")).foregroundStyle(.secondary) }
                    else { Button(NSLocalizedString("page.252", tableName: "Pages", bundle: .main, value: "Отменить проверку", comment: "")) { cancel() } }
                } else {
                    Button(NSLocalizedString("page.253", tableName: "Pages", bundle: .main, value: "Проверить по этому адресу", comment: "")) { probe() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!loaded || !consent || validatedEndpoint == nil)
                }
                Button(NSLocalizedString("page.218", tableName: "Pages", bundle: .main, value: "Закрыть", comment: "")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 760)
        .task {
            do {
                preference = try await ProxyDiagnosticPreferenceStore(paths: paths).load()
                address = preference?.endpoint.address ?? ""
                loaded = true
            } catch { message = error.localizedDescription }
        }
        .onChange(of: address) { _, _ in cancel(); consent = false }
        .onChange(of: consent) { _, value in if !value { cancel() } }
        .onChange(of: configuration) { _, _ in cancel(); consent = false }
        .onChange(of: contextRevision) { _, _ in cancel(); consent = false }
        .onDisappear { cancel() }
    }

    private var validatedEndpoint: ProxyDiagnosticEndpoint? { try? .init(address) }

    private func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
        isSaving = false
        observation = nil
        message = nil
    }

    private func save() {
        guard let endpoint = validatedEndpoint else { return }
        cancel()
        let token = requestID
        let expectedRevision = preference?.revision
        isSaving = true
        task = Task { @MainActor in
            do {
                let next = try await ProxyDiagnosticPreferenceStore(paths: paths).save(endpoint, expectedRevision: expectedRevision)
                guard !Task.isCancelled, requestID == token else { return }
                preference = next
                isSaving = false
                message = NSLocalizedString("page.254", tableName: "Pages", bundle: .main, value: "Адрес сохранён. Запрос не отправлялся.", comment: "")
                task = nil
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                message = error.localizedDescription
                isSaving = false
                task = nil
            }
        }
    }

    private func probe() {
        guard let endpoint = validatedEndpoint, consent else { return }
        cancel()
        let token = requestID
        let proxy = configuration
        let expectedPreferenceRevision = preference?.revision
        task = Task { @MainActor in
            do {
                let result = try await ProxyDiagnosticRequest.run(
                    endpoint: endpoint, configuration: proxy, readPassword: readPassword,
                    snapshotIsCurrent: snapshotIsCurrent,
                    requestIsCurrent: { requestID == token },
                    validateSavedPreference: {
                        let current = try await ProxyDiagnosticPreferenceStore(paths: paths).load()
                        guard current?.revision == expectedPreferenceRevision else { throw ProxyDiagnosticError.revisionConflict }
                    },
                    validatePreferenceAtPublication: {
                        try ProxyDiagnosticPreferenceStore(paths: paths).validateRevisionForPublication(expectedPreferenceRevision)
                    }
                )
                // No suspension between the validated request and publication.
                guard !Task.isCancelled, requestID == token else { return }
                observation = result
                task = nil
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                message = error is CancellationError ? NSLocalizedString("page.255", tableName: "Pages", bundle: .main, value: "Настройки изменились. Повтори проверку.", comment: "") : error.localizedDescription
                task = nil
            }
        }
    }
}
