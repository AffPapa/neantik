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
            Label("Свой адрес диагностики", systemImage: "network")
                .font(.title2.bold())
            Text("Ручной запрос через выбранный прокси. Адрес сохранится для следующих проверок, но вставка и сохранение не отправляют запрос.")
                .foregroundStyle(.secondary)
            TextField("https://your-domain.example/ip", text: $address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("HTTPS-адрес диагностики прокси")
                .disabled(!loaded || isSaving)
            Text("Ответ: JSON с полем ip — IPv4 или IPv6. Без переадресаций, query и fragment. Другие поля не меняют язык, часовой пояс или настройки профиля.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Разрешаю запрос этому сервису через настроенный прокси", isOn: $consent)
                .disabled(isSaving)
            if let observation {
                Label("Сервис доступен через прокси · \(observation.responseTimeMilliseconds) мс", systemImage: "checkmark.circle")
                Text("Заявленный сервисом IP: \(observation.ipAddress)")
                    .textSelection(.enabled)
                Text("Это результат curl на момент проверки. Маршрут Chromium не измерен; GeoIP и подготовка запуска проверяются отдельно.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Сохранить адрес") { save() }
                    .disabled(!loaded || task != nil || validatedEndpoint == nil)
                Spacer()
                if task != nil {
                    ProgressView().controlSize(.small)
                    if isSaving { Text("Сохраняем адрес…").foregroundStyle(.secondary) }
                    else { Button("Отменить проверку") { cancel() } }
                } else {
                    Button("Проверить по этому адресу") { probe() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!loaded || !consent || validatedEndpoint == nil)
                }
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
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
                message = "Адрес сохранён. Запрос не отправлялся."
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
        task = Task { @MainActor in
            do {
                let result = try await ProxyDiagnosticRequest.run(
                    endpoint: endpoint, configuration: proxy, readPassword: readPassword,
                    snapshotIsCurrent: snapshotIsCurrent,
                    requestIsCurrent: { requestID == token }
                )
                guard !Task.isCancelled, requestID == token else { return }
                // Another window may have changed the saved policy while the
                // network request was in flight. Never display a stale success.
                let current = try await ProxyDiagnosticPreferenceStore(paths: paths).load()
                guard !Task.isCancelled, requestID == token else { return }
                guard current?.revision == preference?.revision else { throw ProxyDiagnosticError.revisionConflict }
                observation = result
                task = nil
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                message = error is CancellationError ? "Настройки изменились. Повтори проверку." : error.localizedDescription
                task = nil
            }
        }
    }
}
