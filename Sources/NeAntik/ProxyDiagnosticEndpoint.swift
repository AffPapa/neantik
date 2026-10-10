import Darwin
import Foundation

/// Manual IP-only diagnostics. This evidence never supplies GeoIP launch
/// context or qualifies the network route of a running Chromium session.
struct ProxyDiagnosticEndpoint: Equatable, Codable, Sendable {
    let address: String

    init(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 2_048,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: text), parts.scheme == "https",
              let host = parts.host, !host.isEmpty,
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !parts.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = parts.url, url.absoluteString == text
        else { throw ProxyDiagnosticError.invalidAddress }
        address = text
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(address)
    }
}

enum ProxyDiagnosticError: LocalizedError, Equatable {
    case invalidAddress, consentRequired, unavailableSettings, revisionConflict
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Укажи полный HTTPS-адрес без логина, пароля, query и fragment. Например: https://your-domain.example/ip."
        case .consentRequired: "Подтверди отправку запроса выбранному сервису через настроенный прокси."
        case .unavailableSettings: "Настройки адреса диагностики недоступны. Файл сохранён; проверь его перед повтором."
        case .revisionConflict: "Адрес диагностики изменён в другом окне. Закрой и открой эту проверку заново."
        }
    }
}

struct ProxyDiagnosticPreference: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: UUID
    let endpoint: ProxyDiagnosticEndpoint

    init(endpoint: ProxyDiagnosticEndpoint) {
        schemaVersion = 1
        revision = UUID()
        self.endpoint = endpoint
    }
}

/// Reads and writes run off the main actor. Cross-manager writes use a private
/// advisory guard and compare the persisted revision before atomic replacement.
struct ProxyDiagnosticPreferenceStore: Sendable {
    let paths: AppPaths
    var write: @Sendable (AppPaths, Data, URL) throws -> Void = { try $0.writePrivateFile($1, to: $2) }

    func load() async throws -> ProxyDiagnosticPreference? {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try paths.prepareBaseDirectories()
            return try paths.withProxyDiagnosticGuard { try read() }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func save(_ endpoint: ProxyDiagnosticEndpoint, expectedRevision: UUID?) async throws -> ProxyDiagnosticPreference {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try paths.prepareBaseDirectories()
            return try paths.withProxyDiagnosticGuard {
                guard try read()?.revision == expectedRevision else { throw ProxyDiagnosticError.revisionConflict }
                try Task.checkCancellation()
                let next = ProxyDiagnosticPreference(endpoint: endpoint)
                try write(paths, JSONEncoder().encode(next), paths.proxyDiagnosticPreferenceFile)
                return next
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func read() throws -> ProxyDiagnosticPreference? {
        let file = paths.proxyDiagnosticPreferenceFile
        try paths.validatePrivateFile(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw ProxyDiagnosticError.unavailableSettings }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_nlink == 1,
              status.st_uid == geteuid(), status.st_size > 0, status.st_size <= 4_096
        else { throw ProxyDiagnosticError.unavailableSettings }
        var bytes = [UInt8](repeating: 0, count: Int(status.st_size))
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ProxyDiagnosticError.unavailableSettings }
            offset += count
        }
        var after = stat(), entry = stat()
        guard fstat(descriptor, &after) == 0, lstat(file.path, &entry) == 0,
              after.st_dev == status.st_dev, after.st_ino == status.st_ino,
              after.st_size == status.st_size, after.st_nlink == 1,
              after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
              entry.st_dev == after.st_dev, entry.st_ino == after.st_ino,
              entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { throw ProxyDiagnosticError.unavailableSettings }
        do {
            let value = try JSONDecoder().decode(ProxyDiagnosticPreference.self, from: Data(bytes))
            guard value.schemaVersion == 1 else { throw ProxyDiagnosticError.unavailableSettings }
            return value
        } catch { throw ProxyDiagnosticError.unavailableSettings }
    }
}

struct ProxyDiagnosticObservation: Equatable, Sendable {
    let observedAt: Date
    let responseTimeMilliseconds: Int
    let ipAddress: String
}

/// Revalidate after every suspension, especially the Keychain read before
/// sending credentials. The view token also prevents an old cancelled request
/// from publishing into a replacement request's state.
@MainActor
enum ProxyDiagnosticRequest {
    static func run(
        endpoint: ProxyDiagnosticEndpoint, configuration: ProxyConfiguration,
        readPassword: @Sendable () async throws -> String,
        snapshotIsCurrent: @MainActor () async throws -> Bool,
        requestIsCurrent: @MainActor () -> Bool,
        runProcess: ProxyTester.ProcessRunner = ProxyTester.runCancellableProcess
    ) async throws -> ProxyDiagnosticObservation {
        func validate() async throws {
            try Task.checkCancellation()
            guard requestIsCurrent() else { throw CancellationError() }
            let matches = try await snapshotIsCurrent()
            try Task.checkCancellation()
            guard requestIsCurrent(), matches else { throw CancellationError() }
        }
        try await validate()
        let password = try await readPassword()
        try await validate()
        let result = try await ProxyTester().diagnose(
            endpoint: endpoint, configuration: configuration, password: password,
            consent: true, runProcess: runProcess
        )
        try await validate()
        let currentPassword = try await readPassword()
        try await validate()
        guard currentPassword == password else { throw CancellationError() }
        return result
    }
}
