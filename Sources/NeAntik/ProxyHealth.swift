import Darwin
import Foundation

@_silgen_name("flock")
private func proxyHealthFlock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

enum ProxyHealthOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case invalidConfiguration
    case nameResolutionFailed
    case timedOut
    case connectionFailed
    case authenticationRejected
    case transportSecurityFailed
    case protocolFailed
    case probeServiceFailed
    case invalidResponse
    case internalFailure

    var userSummary: String {
        switch self {
        case .succeeded:
            "Проверка прошла успешно."
        case .invalidConfiguration:
            "Проверь тип, адрес и порт прокси."
        case .nameResolutionFailed:
            "Не удалось найти адрес прокси."
        case .timedOut:
            "Прокси не ответил за 12 секунд."
        case .connectionFailed:
            "Соединение с прокси не установлено."
        case .authenticationRejected:
            "Прокси отклонил логин или пароль."
        case .transportSecurityFailed:
            "Защищённое соединение не установлено."
        case .protocolFailed:
            "Прокси ответил в неподдерживаемом формате."
        case .probeServiceFailed:
            "Сервис проверки недоступен; состояние прокси " +
                "не определено."
        case .invalidResponse:
            "Получен некорректный ответ; состояние прокси " +
                "не определено."
        case .internalFailure:
            "Проверку не удалось запустить."
        }
    }
}

enum ProxyHealthSource: String, Codable, Equatable, Sendable {
    case ipAPI = "ipapi.co"
}

struct ProxyHealthAttempt: Codable, Equatable, Sendable {
    static let maximumResponseTimeMilliseconds = 120_000

    let checkedAt: Date
    let outcome: ProxyHealthOutcome
    let responseTimeMilliseconds: Int?

    init(
        checkedAt: Date,
        outcome: ProxyHealthOutcome,
        responseTimeMilliseconds: Int? = nil
    ) {
        self.checkedAt = checkedAt
        self.outcome = outcome
        self.responseTimeMilliseconds = responseTimeMilliseconds.flatMap {
            (0...Self.maximumResponseTimeMilliseconds).contains($0)
                ? $0
                : nil
        }
    }
}

struct ProxyHealthSuccess: Codable, Equatable, Sendable {
    let observedAt: Date
    let source: ProxyHealthSource
    let responseTimeMilliseconds: Int
    let exitAddressWasObserved: Bool
    let city: String?
    let countryName: String?
    let countryCode: String?
    let timezoneIdentifier: String?
    let localeIdentifier: String?

    init(
        observedAt: Date,
        source: ProxyHealthSource = .ipAPI,
        responseTimeMilliseconds: Int,
        exitAddressWasObserved: Bool,
        city: String?,
        countryName: String?,
        countryCode: String?,
        timezoneIdentifier: String?,
        localeIdentifier: String?
    ) {
        self.observedAt = observedAt
        self.source = source
        self.responseTimeMilliseconds = min(
            max(0, responseTimeMilliseconds),
            ProxyHealthAttempt.maximumResponseTimeMilliseconds
        )
        self.exitAddressWasObserved = exitAddressWasObserved
        self.city = city
        self.countryName = countryName
        self.countryCode = countryCode
        self.timezoneIdentifier = timezoneIdentifier
        self.localeIdentifier = localeIdentifier
    }

    var locationSummary: String {
        [city, countryName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct ProxyHealthState: Codable, Equatable, Sendable {
    let latestAttempt: ProxyHealthAttempt
    let lastSuccess: ProxyHealthSuccess?

    var hasCompleteRouteContext: Bool {
        latestAttempt.outcome == .succeeded &&
            lastSuccess?.exitAddressWasObserved == true &&
            lastSuccess?.timezoneIdentifier != nil &&
            lastSuccess?.localeIdentifier != nil
    }
}

/// Exact proxy configuration revision that produced a health observation.
///
/// `ProxyConfiguration` intentionally excludes the password. Binding the
/// profile revision as well ensures a credential edit invalidates the result
/// without persisting a secret or a password-derived value.
struct ProxyHealthIdentity: Codable, Equatable, Sendable {
    let proxy: ProxyConfiguration
    let profileRevision: UInt64

    init(proxy: ProxyConfiguration, profileRevision: UInt64) {
        self.proxy = proxy
        self.profileRevision = profileRevision
    }

    init?(profile: BrowserProfile) {
        guard let proxy = profile.proxy else { return nil }
        self.init(proxy: proxy, profileRevision: profile.revision)
    }
}

struct ProxyHealthRecord: Codable, Equatable, Sendable {
    let identity: ProxyHealthIdentity?
    let state: ProxyHealthState
}

struct ProxyHealthRecordReplacement: Equatable, Sendable {
    let previousRecord: ProxyHealthRecord?
    let persistedRecord: ProxyHealthRecord?
}

enum ProxyHealthUpdatePolicy {
    static func success(
        _ observation: ProxyTestObservation
    ) -> ProxyHealthState {
        let success = ProxyHealthSuccess(
            observedAt: observation.observedAt,
            responseTimeMilliseconds: observation.responseTimeMilliseconds,
            exitAddressWasObserved: !observation.result.ipAddress.isEmpty,
            city: observation.result.city,
            countryName: observation.result.countryName,
            countryCode: observation.result.countryCode,
            timezoneIdentifier: observation.result.timezoneIdentifier,
            localeIdentifier: observation.result.localeIdentifier
        )
        return ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: observation.observedAt,
                outcome: .succeeded,
                responseTimeMilliseconds:
                    observation.responseTimeMilliseconds
            ),
            lastSuccess: success
        )
    }

    static func failure(
        _ error: ProxyProbeError,
        checkedAt: Date,
        previous: ProxyHealthState?
    ) -> ProxyHealthState {
        ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: checkedAt,
                outcome: error.outcome
            ),
            lastSuccess: previous?.lastSuccess
        )
    }

    static func applying(
        _ result: Result<ProxyTestObservation, Error>,
        checkedAt: Date,
        previous: ProxyHealthState?
    ) -> ProxyHealthState? {
        switch result {
        case let .success(observation):
            success(observation)
        case let .failure(error as ProxyProbeError):
            failure(error, checkedAt: checkedAt, previous: previous)
        case let .failure(error) where error is CancellationError:
            previous
        case .failure:
            ProxyHealthState(
                latestAttempt: ProxyHealthAttempt(
                    checkedAt: checkedAt,
                    outcome: .internalFailure
                ),
                lastSuccess: previous?.lastSuccess
            )
        }
    }
}

private struct ProxyHealthStoreEnvelopeV1: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var states: [String: ProxyHealthState]
}

private struct ProxyHealthStoreEnvelopeV2: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var records: [String: ProxyHealthRecord]
}

private struct ProxyHealthStoreEnvelopeHeader: Decodable {
    let schemaVersion: Int
}

enum ProxyHealthStoreError: LocalizedError, Equatable {
    case unsupportedSchema
    case unsafePath
    case capacityExceeded

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            "Формат истории проверок прокси не " +
                "поддерживается."
        case .unsafePath:
            "Историю проверок прокси нельзя безопасно " +
                "открыть."
        case .capacityExceeded:
            "История проверок прокси достигла безопасного лимита."
        }
    }
}

actor ProxyHealthStore {
    static let maximumFileBytes = 4 * 1_024 * 1_024

    let fileURL: URL
    private var records: [String: ProxyHealthRecord]

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        records = try Self.loadRecords(from: fileURL)
    }

    func state(for profileID: UUID) -> ProxyHealthState? {
        records[profileID.uuidString]?.state
    }

    func state(
        for profileID: UUID,
        matching identity: ProxyHealthIdentity
    ) -> ProxyHealthState? {
        guard let record = records[profileID.uuidString],
              record.identity == identity
        else {
            return nil
        }
        return record.state
    }

    func allRecords() -> [UUID: ProxyHealthRecord] {
        records.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) {
                result[id] = entry.value
            }
        }
    }

    func prune(
        retaining identities: [UUID: ProxyHealthIdentity]
    ) throws -> [UUID: ProxyHealthRecord] {
        let previous = records
        let identitiesByKey = Dictionary(
            uniqueKeysWithValues: identities.map {
                ($0.key.uuidString, $0.value)
            }
        )
        do {
            let persisted = try Self.withExclusiveFileLock(for: fileURL) {
                let merged = try Self.loadRecords(from: fileURL)
                let retained = merged.filter { key, record in
                    guard let identity = identitiesByKey[key] else {
                        return false
                    }
                    return record.identity == identity
                }
                if retained != merged {
                    try Self.persistRecords(retained, to: fileURL)
                }
                return retained
            }
            records = persisted
            return persisted.reduce(into: [:]) { result, entry in
                if let id = UUID(uuidString: entry.key) {
                    result[id] = entry.value
                }
            }
        } catch {
            records = previous
            throw error
        }
    }

    func set(
        _ state: ProxyHealthState?,
        for profileID: UUID
    ) throws {
        try replaceRecord(
            state.map { ProxyHealthRecord(identity: nil, state: $0) },
            for: profileID
        )
    }

    func set(
        _ state: ProxyHealthState?,
        for profileID: UUID,
        identity: ProxyHealthIdentity
    ) throws {
        try replaceRecord(
            state.map {
                ProxyHealthRecord(identity: identity, state: $0)
            },
            for: profileID
        )
    }

    func removeAll() throws {
        let previous = records
        do {
            records = try Self.withExclusiveFileLock(for: fileURL) {
                let empty: [String: ProxyHealthRecord] = [:]
                try Self.persistRecords(empty, to: fileURL)
                return empty
            }
        } catch {
            records = previous
            throw error
        }
    }

    /// Atomically replaces one record and returns the exact value observed
    /// under the same file lock immediately before the write.
    ///
    /// The receipt is used to compensate a cancellation that arrives while
    /// the atomic file write is in progress. Reading the previous value before
    /// acquiring this lock would be stale when another store instance writes
    /// the same file.
    @discardableResult
    func replaceRecord(
        _ record: ProxyHealthRecord?,
        for profileID: UUID
    ) throws -> ProxyHealthRecordReplacement {
        let previous = records
        do {
            let transaction = try Self.withExclusiveFileLock(for: fileURL) {
                var merged = try Self.loadRecords(from: fileURL)
                let replaced = merged[profileID.uuidString]
                merged[profileID.uuidString] = record
                try Self.persistRecords(merged, to: fileURL)
                let persisted = try Self.loadRecords(from: fileURL)
                return (
                    persisted,
                    ProxyHealthRecordReplacement(
                        previousRecord: replaced,
                        persistedRecord: persisted[profileID.uuidString]
                    )
                )
            }
            records = transaction.0
            return transaction.1
        } catch {
            records = previous
            throw error
        }
    }

    /// Restores a transaction receipt only while the record still equals the
    /// value written by that transaction.
    ///
    /// A different store or process may have committed a newer value after the
    /// cancelled write. The compare-and-swap guard preserves that newer value
    /// instead of turning cancellation compensation into a lost update.
    @discardableResult
    func restoreRecord(
        _ previousRecord: ProxyHealthRecord?,
        replacing expectedRecord: ProxyHealthRecord,
        for profileID: UUID
    ) throws -> Bool {
        let previous = records
        do {
            let transaction = try Self.withExclusiveFileLock(for: fileURL) {
                var merged = try Self.loadRecords(from: fileURL)
                guard merged[profileID.uuidString] == expectedRecord else {
                    return (merged, false)
                }
                merged[profileID.uuidString] = previousRecord
                try Self.persistRecords(merged, to: fileURL)
                return (merged, true)
            }
            records = transaction.0
            return transaction.1
        } catch {
            records = previous
            throw error
        }
    }

    nonisolated static func load(
        from fileURL: URL
    ) throws -> [String: ProxyHealthState] {
        try loadRecords(from: fileURL).mapValues(\.state)
    }

    nonisolated private static func loadRecords(
        from fileURL: URL
    ) throws -> [String: ProxyHealthRecord] {
        let status = try entryStatus(at: fileURL)
        guard let status else {
            return [:]
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0,
              status.st_size <= Self.maximumFileBytes
        else {
            throw ProxyHealthStoreError.unsafePath
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(
            ProxyHealthStoreEnvelopeHeader.self,
            from: data
        )
        let records: [String: ProxyHealthRecord]
        switch header.schemaVersion {
        case 1:
            let legacy = try decoder.decode(
                ProxyHealthStoreEnvelopeV1.self,
                from: data
            )
            records = legacy.states.mapValues {
                ProxyHealthRecord(identity: nil, state: $0)
            }
        case ProxyHealthStoreEnvelopeV2.currentSchemaVersion:
            records = try decoder.decode(
                ProxyHealthStoreEnvelopeV2.self,
                from: data
            ).records
        default:
            throw ProxyHealthStoreError.unsupportedSchema
        }
        guard records.count <= ProfileStorageLimits.maximumProfileCount,
              records.allSatisfy({ entry in
                UUID(uuidString: entry.key)?.uuidString == entry.key &&
                    isValid(entry.value)
              })
        else {
            throw ProxyHealthStoreError.unsafePath
        }
        return records
    }

    nonisolated static func persist(
        _ states: [String: ProxyHealthState],
        to fileURL: URL
    ) throws {
        try persistRecords(
            states.mapValues {
                ProxyHealthRecord(identity: nil, state: $0)
            },
            to: fileURL
        )
    }

    nonisolated private static func persistRecords(
        _ records: [String: ProxyHealthRecord],
        to fileURL: URL
    ) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let status = try entryStatus(at: fileURL),
           status.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG)
        {
            throw ProxyHealthStoreError.unsafePath
        }
        guard records.count <= ProfileStorageLimits.maximumProfileCount,
              records.allSatisfy({ entry in
                UUID(uuidString: entry.key)?.uuidString == entry.key &&
                    isValid(entry.value)
              })
        else {
            throw ProxyHealthStoreError.unsafePath
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            ProxyHealthStoreEnvelopeV2(
                schemaVersion:
                    ProxyHealthStoreEnvelopeV2.currentSchemaVersion,
                records: records
            )
        )
        guard data.count <= Self.maximumFileBytes else {
            throw ProxyHealthStoreError.capacityExceeded
        }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    nonisolated private static func entryStatus(
        at fileURL: URL
    ) throws -> stat? {
        var status = stat()
        let result = fileURL.path.withCString {
            Darwin.lstat($0, &status)
        }
        if result != 0 {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return status
    }

    nonisolated private static func withExclusiveFileLock<T>(
        for fileURL: URL,
        _ operation: () throws -> T
    ) throws -> T {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw ProxyHealthStoreError.unsafePath
        }
        defer { _ = Darwin.close(descriptor) }

        while proxyHealthFlock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
        }
        defer { _ = proxyHealthFlock(descriptor, LOCK_UN) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              openedStatus.st_nlink == 1
        else {
            throw ProxyHealthStoreError.unsafePath
        }
        var pathStatus = stat()
        let pathResult = lockURL.path.withCString {
            Darwin.lstat($0, &pathStatus)
        }
        guard pathResult == 0,
              pathStatus.st_dev == openedStatus.st_dev,
              pathStatus.st_ino == openedStatus.st_ino,
              pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw ProxyHealthStoreError.unsafePath
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return try operation()
    }

    nonisolated private static func isValid(
        _ record: ProxyHealthRecord
    ) -> Bool {
        if let identity = record.identity,
           !identity.proxy.isValid
        {
            return false
        }
        let state = record.state
        guard state.latestAttempt.checkedAt.timeIntervalSinceReferenceDate
            .isFinite,
              state.latestAttempt.outcome == .succeeded
                ? state.latestAttempt.responseTimeMilliseconds != nil
                : state.latestAttempt.responseTimeMilliseconds == nil
        else {
            return false
        }
        guard let success = state.lastSuccess else {
            return state.latestAttempt.outcome != .succeeded
        }
        let texts = [
            success.city,
            success.countryName,
            success.countryCode,
            success.timezoneIdentifier,
            success.localeIdentifier
        ].compactMap { $0 }
        return success.observedAt.timeIntervalSinceReferenceDate.isFinite &&
            (0...ProxyHealthAttempt.maximumResponseTimeMilliseconds)
                .contains(success.responseTimeMilliseconds) &&
            texts.allSatisfy {
                $0.utf8.count <= 128 &&
                    $0.unicodeScalars.allSatisfy {
                        !CharacterSet.controlCharacters.contains($0)
                    }
            } &&
            (
                state.latestAttempt.outcome != .succeeded ||
                state.latestAttempt.checkedAt == success.observedAt
            )
    }
}
