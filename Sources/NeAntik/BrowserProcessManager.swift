import Combine
import Darwin
import Foundation

enum BrowserProcessLockPhase: String, Codable, Equatable, Sendable {
    case starting
    case running
}

struct BrowserProcessLock: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let ownerToken: UUID?
    let managerPID: pid_t?
    let phase: BrowserProcessLockPhase
    let pid: pid_t
    let executablePath: String
    let browserDataPath: String
    let createdAt: Date

    init(
        pid: pid_t,
        executablePath: String,
        browserDataPath: String,
        createdAt: Date,
        schemaVersion: Int = 1,
        ownerToken: UUID? = nil,
        managerPID: pid_t? = nil,
        phase: BrowserProcessLockPhase = .running
    ) {
        self.schemaVersion = schemaVersion
        self.ownerToken = ownerToken
        self.managerPID = managerPID
        self.phase = phase
        self.pid = pid
        self.executablePath = executablePath
        self.browserDataPath = browserDataPath
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case ownerToken
        case managerPID
        case phase
        case pid
        case executablePath
        case browserDataPath
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        ownerToken = try container.decodeIfPresent(
            UUID.self,
            forKey: .ownerToken
        )
        managerPID = try container.decodeIfPresent(
            pid_t.self,
            forKey: .managerPID
        )
        phase =
            try container.decodeIfPresent(
                BrowserProcessLockPhase.self,
                forKey: .phase
            ) ?? .running
        pid = try container.decode(pid_t.self, forKey: .pid)
        executablePath = try container.decode(
            String.self,
            forKey: .executablePath
        )
        browserDataPath = try container.decode(
            String.self,
            forKey: .browserDataPath
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

enum BrowserProcessIdentityInspection: Equatable, Sendable {
    case expected
    case unrelated
    case unknown
}

enum BrowserDataProcessInspection: Equatable, Sendable {
    case found
    case absent
    case unknown
}

enum BrowserProfileDeletionBlockReason: Equatable, Sendable {
    case managedProcess
    case leasePresent
    case unsafeLease
    case browserDataInUse
    case inspectionUnavailable
}

struct BrowserProfileDeletionBlockedError: LocalizedError, Equatable {
    let reason: BrowserProfileDeletionBlockReason

    var errorDescription: String? {
        switch reason {
        case .managedProcess:
            "Нельзя удалить профиль, пока его браузер запущен."
        case .leasePresent:
            "Профиль используется другим экземпляром NeAntik. Закрой браузер и повтори удаление."
        case .unsafeLease:
            "Файл состояния запуска не прошёл проверку безопасности. Данные профиля не изменены."
        case .browserDataInUse:
            "Данные профиля сейчас используются браузером. Закрой его окно и повтори удаление."
        case .inspectionUnavailable:
            "NeAntik не смог доказать, что данные профиля свободны. Удаление безопасно отменено."
        }
    }
}

struct BrowserProfileDeletedError: LocalizedError, Equatable {
    var errorDescription: String? {
        "Этот профиль уже удалён другим экземпляром NeAntik. Обнови список профилей."
    }
}

private struct BrowserProfileLeaseUnavailableError: LocalizedError {
    let inspection: BrowserDataProcessInspection

    var errorDescription: String? {
        switch inspection {
        case .found:
            "Данные профиля уже используются браузером без файла состояния. Закрой окно браузера вручную."
        case .unknown:
            "NeAntik не смог доказать, что данные профиля свободны. Запуск безопасно отменён."
        case .absent:
            nil
        }
    }
}

enum BrowserProfileProcessState: Equatable, Sendable {
    case stopped
    case managed
    case externalVerified
    case externalManualOnly
    case externalUnverified
    case recoveryRequired

    var isRunning: Bool {
        self != .stopped
    }

    var canRequestStop: Bool {
        self != .externalManualOnly &&
            self != .externalUnverified &&
            self != .recoveryRequired
    }

    var title: String {
        switch self {
        case .stopped:
            "Остановлен"
        case .managed:
            "Запущен"
        case .externalVerified:
            "Запущен другим NeAntik"
        case .externalManualOnly:
            "Запущен другим NeAntik"
        case .externalUnverified:
            "Требуется закрыть вручную"
        case .recoveryRequired:
            "Профиль заблокирован для защиты данных"
        }
    }

    var guidance: String? {
        switch self {
        case .stopped, .managed:
            nil
        case .externalVerified:
            "Профиль запущен другим экземпляром NeAntik. Его можно безопасно остановить здесь."
        case .externalManualOnly:
            "Профиль запущен другим экземпляром NeAntik. Закрой окно браузера вручную; профиль разблокируется автоматически."
        case .externalUnverified:
            "NeAntik видит работающий процесс, но не может безопасно подтвердить его. Закрой окно браузера вручную; профиль разблокируется автоматически."
        case .recoveryRequired:
            "Файл состояния запуска повреждён или недоступен. Закрой окно браузера вручную; NeAntik разблокирует профиль только после безопасной проверки."
        }
    }
}

enum BrowserLaunchPurpose: Equatable, Sendable {
    case normal
    case fingerprintAudit(httpLoopbackPort: UInt16)
}

enum BrowserLaunchBuilder {
    private static let protectedAdditionalArgumentPrefixes = [
        "--user-data-dir",
        "--proxy-server",
        "--no-proxy-server",
        "--proxy-auto-detect",
        "--proxy-pac-url",
        "--proxy-bypass-list",
        "--host-resolver-rules",
        "--force-webrtc-ip-handling-policy",
        "--disable-quic",
        "--dns-prefetch-disable",
        "--fingerprint",
        "--fingerprint-platform",
        "--fingerprint-timezone",
        "--fingerprint-locale",
        "--fingerprinting-client-rects-noise",
        "--fingerprinting-canvas-measuretext-noise",
        "--fingerprinting-canvas-image-data-noise",
        "--timezone",
        "--lang",
        "--accept-lang",
        "--disable-features"
    ]

    static func arguments(
        profile: BrowserProfile,
        browserDataDirectory: URL,
        runtimeCapabilities: BrowserRuntimeCapabilities = [],
        additionalArguments: [String] = [],
        startURLOverride: URL? = nil,
        purpose: BrowserLaunchPurpose = .normal
    ) -> [String] {
        var arguments = [
            "--user-data-dir=\(browserDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-mode",
            "--new-window"
        ]
        var disabledFeatures = Set<String>()

        if runtimeCapabilities.contains(.fingerprintSeed) {
            arguments.append("--fingerprint=\(profile.identity.runtimeSeed)")
            arguments.append("--fingerprinting-client-rects-noise")
            arguments.append("--fingerprinting-canvas-measuretext-noise")
            arguments.append("--fingerprinting-canvas-image-data-noise")
            // The runtime normalizes WebGL but not the WebGPU adapter surface.
            // Keep WebGPU unavailable until it is part of the same reviewed
            // Apple device tuple.
            disabledFeatures.insert("WebGPUService")
        }
        if runtimeCapabilities.contains(.platformOverride) {
            arguments.append("--fingerprint-platform=macos")
        }
        if runtimeCapabilities.contains(.fingerprintSeed),
           let timezone = profile.identity.timezoneIdentifier {
            arguments.append("--fingerprint-timezone=\(timezone)")
            arguments.append("--timezone=\(timezone)")
        }
        if runtimeCapabilities.contains(.fingerprintSeed),
           let locale = profile.identity.localeIdentifier {
            arguments.append("--fingerprint-locale=\(locale)")
            arguments.append("--lang=\(locale)")
            arguments.append("--accept-lang=\(locale)")
        }

        if let proxy = profile.proxy {
            arguments.append("--proxy-server=\(proxy.chromiumServer)")
            arguments.append(
                "--force-webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
            arguments.append("--disable-quic")
            arguments.append("--dns-prefetch-disable")
            // Resolver rules are the primary fail-closed control. Disabling
            // Chromium's asynchronous and secure-DNS paths adds defense in
            // depth so a future resolver path cannot silently bypass them.
            disabledFeatures.formUnion(["AsyncDns", "DnsOverHttps"])
            arguments.append(
                "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE \(proxy.host)"
            )
            let bypass: String
            switch purpose {
            case .normal:
                bypass = "<-loopback>"
            case let .fingerprintAudit(httpLoopbackPort):
                precondition(httpLoopbackPort != 0)
                bypass =
                    "<-loopback>;http://127.0.0.1:" +
                    String(httpLoopbackPort)
            }
            arguments.append("--proxy-bypass-list=\(bypass)")
        } else {
            // "Direct" is an explicit product route. Do not silently inherit
            // a macOS system proxy, PAC file or auto-detection setting.
            arguments.append("--no-proxy-server")
            // Direct profiles still avoid exposing every local interface to
            // WebRTC while retaining ordinary calls over the public route.
            arguments.append(
                "--force-webrtc-ip-handling-policy=default_public_interface_only"
            )
        }

        if !disabledFeatures.isEmpty {
            arguments.append(
                "--disable-features=\(disabledFeatures.sorted().joined(separator: ","))"
            )
        }

        arguments.append(
            contentsOf: sanitizedAdditionalArguments(additionalArguments)
        )
        let startURL =
            startURLOverride ?? normalizedStartURL(profile.startURL)
        arguments.append(startURL.absoluteString)
        return arguments
    }

    static func sanitizedAdditionalArguments(
        _ arguments: [String]
    ) -> [String] {
        arguments.filter { argument in
            let trimmed = argument.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard trimmed == argument, !trimmed.isEmpty else {
                return false
            }
            return !protectedAdditionalArgumentPrefixes.contains { prefix in
                trimmed == prefix || trimmed.hasPrefix("\(prefix)=")
            }
        }
    }

    static func normalizedStartURL(_ value: String) -> URL {
        validatedStartURL(value) ??
            URL(string: "https://www.google.com")!
    }

    static func validatedStartURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = url.host,
           !host.isEmpty,
           url.user == nil,
           url.password == nil
        {
            return url
        }
        if URL(string: trimmed)?.scheme != nil {
            return nil
        }
        if let url = URL(string: "https://\(trimmed)"),
           let host = url.host,
           !host.isEmpty,
           url.user == nil,
           url.password == nil
        {
            return url
        }
        return nil
    }
}

private struct BrowserProcessRecoveryRecord: Equatable, Sendable {
    let lockURL: URL
    let expectedBrowserDataDirectory: URL
    let removableSnapshot: Data?
    let blockingManagerPID: pid_t?
    let startingCreatedAt: Date?
    let message: String
    let entryIdentity: PrivateFileEntryIdentity?
}

private enum BrowserLeaseEntrySnapshot: Sendable {
    case missing
    case unsafe
    case unreadable
    case data(Data)
}

private enum BrowserRecoveryEntryChange: Equatable, Sendable {
    case unchanged
    case missing
    case changed
    case unsafe
    case unavailable
}

private struct BrowserLeaseReadResult: Sendable {
    let entry: BrowserLeaseEntrySnapshot
    let identity: PrivateFileEntryIdentity?
}

@MainActor
final class BrowserProcessManager: ObservableObject {
    @Published private(set) var runningProfileIDs = Set<UUID>()
    @Published var lastError: String?

    private let paths: AppPaths
    private let processIdentityInspector:
        (BrowserProcessLock) -> BrowserProcessIdentityInspection
    private let processLivenessValidator: (pid_t) -> Bool
    private let browserDataProcessInspector:
        (URL) -> BrowserDataProcessInspection
    private let processSignaler: (pid_t, Int32) -> Int32
    private let managedProcessTerminator: (Process) -> Void
    private let allowsExternalProcessSignaling: Bool
    private let observationIntervalNanoseconds: UInt64
    private let startingLeaseTimeout: TimeInterval
    private let now: () -> Date
    private var processes: [UUID: Process] = [:]
    private var managedLeaseOwners: [UUID: UUID] = [:]
    private var externalLocks: [UUID: BrowserProcessLock] = [:]
    private var externalUnverifiedProfileIDs = Set<UUID>()
    private var recoveryProfileIDs = Set<UUID>()
    private var recoveryRecords: [UUID: BrowserProcessRecoveryRecord] = [:]
    private var externalStopTasks: [UUID: Task<Void, Never>] = [:]
    private var externalObservationTasks: [UUID: Task<Void, Never>] = [:]
    private var recoveryObservationTasks: [UUID: Task<Void, Never>] = [:]
    private var tombstoneObservationTasks: [UUID: Task<Void, Never>] = [:]
    private var tombstoneRecoveryMessages: [UUID: String] = [:]
    private var passiveObservationsEnabled = true

    init(paths: AppPaths) {
        self.paths = paths
        self.processIdentityInspector = {
            BrowserProcessManager.inspectProcess($0)
        }
        self.processLivenessValidator = {
            BrowserProcessManager.isProcessAlive($0)
        }
        self.browserDataProcessInspector = {
            BrowserProcessManager.inspectBrowserDataProcess($0)
        }
        self.processSignaler = { Darwin.kill($0, $1) }
        self.managedProcessTerminator = { $0.terminate() }
        self.allowsExternalProcessSignaling = false
        self.observationIntervalNanoseconds = 1_000_000_000
        self.startingLeaseTimeout = 30
        self.now = Date.init
    }

    init(
        paths: AppPaths,
        processIdentityValidator: @escaping (BrowserProcessLock) -> Bool,
        processLivenessValidator: @escaping (pid_t) -> Bool = {
            BrowserProcessManager.isProcessAlive($0)
        },
        processSignaler: @escaping (pid_t, Int32) -> Int32 = {
            Darwin.kill($0, $1)
        },
        managedProcessTerminator: @escaping (Process) -> Void = {
            $0.terminate()
        },
        observationIntervalNanoseconds: UInt64 = 1_000_000_000,
        browserDataProcessInspector: @escaping
            (URL) -> BrowserDataProcessInspection = {
                BrowserProcessManager.inspectBrowserDataProcess($0)
            },
        allowsExternalProcessSignaling: Bool = true,
        startingLeaseTimeout: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.paths = paths
        self.processIdentityInspector = {
            processIdentityValidator($0) ? .expected : .unrelated
        }
        self.processLivenessValidator = processLivenessValidator
        self.browserDataProcessInspector = browserDataProcessInspector
        self.processSignaler = processSignaler
        self.managedProcessTerminator = managedProcessTerminator
        self.allowsExternalProcessSignaling =
            allowsExternalProcessSignaling
        self.observationIntervalNanoseconds =
            observationIntervalNanoseconds
        self.startingLeaseTimeout = max(0, startingLeaseTimeout)
        self.now = now
    }

    init(
        paths: AppPaths,
        processIdentityInspector: @escaping
            (BrowserProcessLock) -> BrowserProcessIdentityInspection,
        processLivenessValidator: @escaping (pid_t) -> Bool,
        processSignaler: @escaping (pid_t, Int32) -> Int32 = {
            Darwin.kill($0, $1)
        },
        managedProcessTerminator: @escaping (Process) -> Void = {
            $0.terminate()
        },
        observationIntervalNanoseconds: UInt64 = 1_000_000_000,
        browserDataProcessInspector: @escaping
            (URL) -> BrowserDataProcessInspection = {
                BrowserProcessManager.inspectBrowserDataProcess($0)
            },
        allowsExternalProcessSignaling: Bool = true,
        startingLeaseTimeout: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.paths = paths
        self.processIdentityInspector = processIdentityInspector
        self.processLivenessValidator = processLivenessValidator
        self.browserDataProcessInspector = browserDataProcessInspector
        self.processSignaler = processSignaler
        self.managedProcessTerminator = managedProcessTerminator
        self.allowsExternalProcessSignaling =
            allowsExternalProcessSignaling
        self.observationIntervalNanoseconds =
            observationIntervalNanoseconds
        self.startingLeaseTimeout = max(0, startingLeaseTimeout)
        self.now = now
    }

    func reconcile(profiles: [BrowserProfile]) {
        externalStopTasks.values.forEach { $0.cancel() }
        externalStopTasks.removeAll()
        passiveObservationsEnabled = true
        cancelPassiveObservationTasks()
        if tombstoneRecoveryMessages.values.contains(
            where: { $0 == lastError }
        ) {
            lastError = nil
        }
        tombstoneRecoveryMessages.removeAll()
        externalLocks.removeAll()
        externalUnverifiedProfileIDs.removeAll()
        recoveryProfileIDs.removeAll()
        recoveryRecords.removeAll()
        runningProfileIDs = Set(
            processes.compactMap { key, process in
                process.isRunning ? key : nil
            }
        )

        for profile in profiles {
            reconcileProfile(profileID: profile.id)
        }
    }

    func suspendPassiveObservations() {
        passiveObservationsEnabled = false
        cancelPassiveObservationTasks()
    }

    private func cancelPassiveObservationTasks() {
        externalObservationTasks.values.forEach { $0.cancel() }
        externalObservationTasks.removeAll()
        recoveryObservationTasks.values.forEach { $0.cancel() }
        recoveryObservationTasks.removeAll()
        tombstoneObservationTasks.values.forEach { $0.cancel() }
        tombstoneObservationTasks.removeAll()
    }

    func processState(for profileID: UUID) -> BrowserProfileProcessState {
        if processes[profileID]?.isRunning == true {
            return .managed
        }
        if recoveryProfileIDs.contains(profileID) {
            return .recoveryRequired
        }
        if externalUnverifiedProfileIDs.contains(profileID) {
            return .externalUnverified
        }
        if !allowsExternalProcessSignaling &&
            externalLocks[profileID] != nil
        {
            return .externalManualOnly
        }
        if externalLocks[profileID] != nil {
            return .externalVerified
        }
        return runningProfileIDs.contains(profileID) ? .managed : .stopped
    }

    func withVerifiedProfileDeletion<T>(
        profileID: UUID,
        _ destructiveOperation: () throws -> T
    ) throws -> T {
        if processes[profileID]?.isRunning == true {
            throw BrowserProfileDeletionBlockedError(
                reason: .managedProcess
            )
        }

        var destructiveOperationStarted = false
        do {
            return try paths.withProcessLockGuard(for: profileID) {
                switch try paths.privateFileEntryKind(
                    paths.profileDeletionTombstone(for: profileID)
                ) {
                case .regular, .unsafe:
                    throw BrowserProfileDeletedError()
                case .missing:
                    break
                }
                switch try paths.privateFileEntryKind(
                    paths.lockFile(for: profileID)
                ) {
                case .regular:
                    throw BrowserProfileDeletionBlockedError(
                        reason: .leasePresent
                    )
                case .unsafe:
                    throw BrowserProfileDeletionBlockedError(
                        reason: .unsafeLease
                    )
                case .missing:
                    break
                }

                switch browserDataProcessInspector(
                    paths.browserDataDirectory(for: profileID)
                ) {
                case .found:
                    throw BrowserProfileDeletionBlockedError(
                        reason: .browserDataInUse
                    )
                case .unknown:
                    throw BrowserProfileDeletionBlockedError(
                        reason: .inspectionUnavailable
                    )
                case .absent:
                    destructiveOperationStarted = true
                    return try destructiveOperation()
                }
            }
        } catch let error as BrowserProfileDeletionBlockedError {
            throw error
        } catch let error as BrowserProfileDeletedError {
            throw error
        } catch {
            if destructiveOperationStarted {
                throw error
            }
            throw BrowserProfileDeletionBlockedError(
                reason: .inspectionUnavailable
            )
        }
    }

    private func reconcileProfile(profileID: UUID) {
        tombstoneObservationTasks[profileID]?.cancel()
        tombstoneObservationTasks.removeValue(forKey: profileID)
        if let message = tombstoneRecoveryMessages.removeValue(
            forKey: profileID
        ), lastError == message {
            lastError = nil
        }
        externalStopTasks[profileID]?.cancel()
        externalStopTasks.removeValue(forKey: profileID)
        externalObservationTasks[profileID]?.cancel()
        externalObservationTasks.removeValue(forKey: profileID)
        recoveryObservationTasks[profileID]?.cancel()
        recoveryObservationTasks.removeValue(forKey: profileID)
        externalLocks.removeValue(forKey: profileID)
        externalUnverifiedProfileIDs.remove(profileID)
        recoveryProfileIDs.remove(profileID)
        recoveryRecords.removeValue(forKey: profileID)
        if processes[profileID]?.isRunning != true {
            runningProfileIDs.remove(profileID)
        }

        let profileDirectory = paths.profileDirectory(for: profileID)
        let browserDataDirectory = paths.browserDataDirectory(for: profileID)
        let lockURL = paths.lockFile(for: profileID)
        do {
            let tombstoneKind = try paths.withProcessLockGuard(
                for: profileID
            ) {
                try paths.privateFileEntryKind(
                    paths.profileDeletionTombstone(for: profileID)
                )
            }
            if tombstoneKind != .missing {
                let message =
                    "Удаление этого профиля не было завершено безопасно. Запуск заблокирован; проверь Корзину macOS или обратись в поддержку."
                recoveryProfileIDs.insert(profileID)
                runningProfileIDs.insert(profileID)
                tombstoneRecoveryMessages[profileID] = message
                lastError = message
                observeDeletionTombstone(profileID: profileID)
                return
            }
        } catch {
            let message =
                "Не удалось проверить состояние удаления профиля. Запуск заблокирован для защиты данных."
            recoveryProfileIDs.insert(profileID)
            runningProfileIDs.insert(profileID)
            tombstoneRecoveryMessages[profileID] = message
            lastError = message
            observeDeletionTombstone(profileID: profileID)
            return
        }

        do {
            try paths.validatePrivateDirectory(profileDirectory)
        } catch {
            guard !Self.isMissingPathError(error) else {
                return
            }
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: nil,
                blockingManagerPID: nil,
                message:
                    "Папка профиля не прошла проверку безопасности. Профиль заблокирован, чтобы не повредить данные браузера."
            )
            return
        }

        let readResult: BrowserLeaseReadResult
        do {
            readResult = try readLeaseEntry(
                profileID: profileID,
                lockURL: lockURL
            )
        } catch {
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: nil,
                blockingManagerPID: nil,
                message:
                    "Файл состояния запуска недоступен. Профиль заблокирован до безопасной проверки."
            )
            return
        }

        let data: Data
        switch readResult.entry {
        case .missing:
            return
        case .unsafe:
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: nil,
                blockingManagerPID: nil,
                message:
                    "Файл состояния запуска имеет небезопасный тип. NeAntik не будет запускать этот профиль повторно."
            )
            return
        case .unreadable:
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: nil,
                blockingManagerPID: nil,
                message:
                    "Файл состояния запуска нельзя прочитать. Профиль заблокирован до безопасной проверки."
            )
            return
        case let .data(value):
            data = value
        }

        let lock: BrowserProcessLock
        do {
            lock = try Self.decodeLock(data)
        } catch {
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: data,
                blockingManagerPID: nil,
                message:
                    "Файл состояния запуска повреждён. NeAntik проверяет, закрыт ли браузер, прежде чем разблокировать профиль."
            )
            return
        }

        let expectedPath =
            browserDataDirectory.standardizedFileURL.path
        guard lock.schemaVersion >= 1,
              lock.schemaVersion <= BrowserProcessLock.currentSchemaVersion,
              URL(fileURLWithPath: lock.browserDataPath)
                .standardizedFileURL.path == expectedPath
        else {
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: data,
                blockingManagerPID: nil,
                message:
                    "Файл состояния запуска не соответствует этому профилю. Профиль остаётся заблокированным для защиты данных."
            )
            return
        }

        if lock.phase == .starting {
            let blockingManagerPID: pid_t?
            if let managerPID = lock.managerPID,
               processLivenessValidator(managerPID)
            {
                blockingManagerPID = managerPID
            } else {
                blockingManagerPID = nil
            }
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: data,
                blockingManagerPID: blockingManagerPID,
                startingCreatedAt: lock.createdAt,
                message:
                    "Другой экземпляр NeAntik ещё запускает этот профиль. Повторный запуск заблокирован."
            )
            return
        }

        guard lock.pid > 0 else {
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: data,
                blockingManagerPID: nil,
                message:
                    "Файл состояния запуска содержит неверный процесс. Профиль остаётся заблокированным до безопасной проверки."
            )
            return
        }

        switch processIdentityInspector(lock) {
        case .expected:
            externalLocks[profileID] = lock
            runningProfileIDs.insert(profileID)
            observeExternalProcess(
                profileID: profileID,
                lock: lock
            )
        case .unknown:
            externalLocks[profileID] = lock
            externalUnverifiedProfileIDs.insert(profileID)
            runningProfileIDs.insert(profileID)
            lastError =
                "NeAntik не смог безопасно проверить уже запущенный браузер. Профиль остаётся заблокированным до завершения процесса."
            observeExternalProcess(
                profileID: profileID,
                lock: lock
            )
        case .unrelated:
            switch browserDataProcessInspector(browserDataDirectory) {
            case .absent:
                if !removeLockIfSnapshotMatches(
                    profileID: profileID,
                    lockURL: lockURL,
                    snapshot: data
                ) {
                    registerRecovery(
                        profileID: profileID,
                        lockURL: lockURL,
                        expectedBrowserDataDirectory: browserDataDirectory,
                        removableSnapshot: data,
                        blockingManagerPID: nil,
                        message:
                            "Файл состояния запуска изменился во время проверки. Профиль остаётся заблокированным."
                    )
                }
            case .found, .unknown:
                registerRecovery(
                    profileID: profileID,
                    lockURL: lockURL,
                    expectedBrowserDataDirectory: browserDataDirectory,
                    removableSnapshot: data,
                    blockingManagerPID: nil,
                    message:
                        "NeAntik не может доказать, что данные профиля свободны. Повторный запуск заблокирован."
                )
            }
        }
    }

    func launch(
        profile: BrowserProfile,
        runtime: BrowserRuntime,
        additionalArguments: [String] = [],
        startURLOverride: URL? = nil,
        browserDataDirectoryOverride: URL? = nil,
        purpose: BrowserLaunchPurpose = .normal
    ) throws {
        guard !runningProfileIDs.contains(profile.id) else {
            throw NeAntikError.profileAlreadyRunning
        }
        guard profile.proxy?.isValid != false else {
            throw NeAntikError.invalidProxy
        }

        let browserDataDirectory =
            browserDataDirectoryOverride ??
            paths.browserDataDirectory(for: profile.id)

        try paths.prepareBaseDirectories()
        let logURL = paths.logFile(for: profile.id)
        try prepareDiagnosticLog(logURL)

        let process = Process()
        process.executableURL = runtime.executableURL
        process.arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: browserDataDirectory,
            runtimeCapabilities: runtime.capabilities,
            additionalArguments: additionalArguments,
            startURLOverride: startURLOverride,
            purpose: purpose
        )
        process.currentDirectoryURL = paths.profileDirectory(for: profile.id)

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                try? self?.appendDiagnostic(
                    "browser_exit reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus)",
                    to: logURL
                )
                self?.handleTermination(profileID: profile.id, process: process)
            }
        }

        let ownerToken = UUID()
        let lockURL = paths.lockFile(for: profile.id)
        let createdAt = Date()
        let provisionalLock = BrowserProcessLock(
            pid: 0,
            executablePath: runtime.executableURL.standardizedFileURL.path,
            browserDataPath: browserDataDirectory.standardizedFileURL.path,
            createdAt: createdAt,
            schemaVersion: BrowserProcessLock.currentSchemaVersion,
            ownerToken: ownerToken,
            managerPID: getpid(),
            phase: .starting
        )
        do {
            try acquireLease(
                provisionalLock,
                profileID: profile.id,
                at: lockURL,
                browserDataDirectory: browserDataDirectory
            )
        } catch where Self.isExistingPathError(error) {
            reconcileProfile(profileID: profile.id)
            guard !runningProfileIDs.contains(profile.id) else {
                throw NeAntikError.profileAlreadyRunning
            }
            do {
                try acquireLease(
                    provisionalLock,
                    profileID: profile.id,
                    at: lockURL,
                    browserDataDirectory: browserDataDirectory
                )
            } catch where Self.isExistingPathError(error) {
                reconcileProfile(profileID: profile.id)
                throw NeAntikError.profileAlreadyRunning
            } catch {
                throw NeAntikError.processLaunchFailed(
                    error.localizedDescription
                )
            }
        } catch {
            throw NeAntikError.processLaunchFailed(error.localizedDescription)
        }
        managedLeaseOwners[profile.id] = ownerToken

        do {
            try process.run()
            processes[profile.id] = process
            runningProfileIDs.insert(profile.id)
            try? appendDiagnostic(
                "browser_launch version=\(runtime.inspection.version ?? "unknown")",
                to: logURL
            )
            let lock = BrowserProcessLock(
                pid: process.processIdentifier,
                executablePath: runtime.executableURL.standardizedFileURL.path,
                browserDataPath: browserDataDirectory.standardizedFileURL.path,
                createdAt: createdAt,
                schemaVersion: BrowserProcessLock.currentSchemaVersion,
                ownerToken: ownerToken,
                managerPID: getpid(),
                phase: .running
            )
            try writeOwnedLease(
                lock,
                profileID: profile.id,
                ownerToken: ownerToken,
                at: lockURL
            )
        } catch {
            if process.isRunning {
                managedProcessTerminator(process)
            }
            if process.isRunning {
                processes[profile.id] = process
                runningProfileIDs.insert(profile.id)
                throw NeAntikError.processLaunchFailed(
                    error.localizedDescription
                )
            }
            processes.removeValue(forKey: profile.id)
            runningProfileIDs.remove(profile.id)
            managedLeaseOwners.removeValue(forKey: profile.id)
            removeLockIfOwned(
                profileID: profile.id,
                ownerToken: ownerToken
            )
            try? appendDiagnostic(
                "browser_launch_failed",
                to: logURL
            )
            throw NeAntikError.processLaunchFailed(error.localizedDescription)
        }
    }

    func stop(profileID: UUID) {
        if let process = processes[profileID], process.isRunning {
            managedProcessTerminator(process)
            return
        }
        if recoveryProfileIDs.contains(profileID) {
            lastError =
                "NeAntik не знает безопасный PID этого браузера. Закрой окно браузера вручную; профиль разблокируется после проверки."
            return
        }
        if let lock = externalLocks[profileID] {
            guard allowsExternalProcessSignaling else {
                lastError =
                    "Этот браузер запущен другим экземпляром NeAntik. Закрой его окно вручную; профиль разблокируется автоматически."
                return
            }
            switch processIdentityInspector(lock) {
            case .unrelated:
                handleTermination(profileID: profileID, process: nil)
                return
            case .unknown:
                lastError =
                    "Не удалось безопасно подтвердить процесс браузера. Закрой его окно вручную; профиль разблокируется после завершения процесса."
                return
            case .expected:
                break
            }
            guard externalStopTasks[profileID] == nil else {
                return
            }
            if processSignaler(lock.pid, SIGTERM) != 0 {
                if errno == ESRCH {
                    handleTermination(profileID: profileID, process: nil)
                    return
                }
                lastError = "Не удалось остановить процесс браузера."
                return
            }
            externalStopTasks[profileID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    externalStopTasks.removeValue(forKey: profileID)
                }
                for _ in 0..<50 {
                    do {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    } catch {
                        return
                    }
                    guard externalLocks[profileID] == lock else {
                        return
                    }
                    if !processLivenessValidator(lock.pid) {
                        handleTermination(
                            profileID: profileID,
                            process: nil
                        )
                        return
                    }
                }
                lastError =
                    "Браузер ещё останавливается. NeAntik оставил профиль заблокированным, чтобы защитить его данные."
            }
            return
        }
        handleTermination(profileID: profileID, process: nil)
    }

    private func handleTermination(profileID: UUID, process: Process?) {
        if let current = processes[profileID],
           let process,
           current !== process {
            return
        }
        let managedOwner = managedLeaseOwners.removeValue(
            forKey: profileID
        )
        let externalLock = externalLocks[profileID]
        let lockURL = paths.lockFile(for: profileID)
        let browserDataDirectory =
            paths.browserDataDirectory(for: profileID)
        let removableSnapshot = currentLeaseSnapshot(
            profileID: profileID,
            managedOwner: managedOwner,
            externalLock: externalLock
        )
        processes.removeValue(forKey: profileID)
        externalStopTasks[profileID]?.cancel()
        externalStopTasks.removeValue(forKey: profileID)
        externalObservationTasks[profileID]?.cancel()
        externalObservationTasks.removeValue(forKey: profileID)
        recoveryObservationTasks[profileID]?.cancel()
        recoveryObservationTasks.removeValue(forKey: profileID)
        externalLocks.removeValue(forKey: profileID)
        externalUnverifiedProfileIDs.remove(profileID)
        recoveryProfileIDs.remove(profileID)
        recoveryRecords.removeValue(forKey: profileID)
        runningProfileIDs.remove(profileID)

        switch browserDataProcessInspector(browserDataDirectory) {
        case .absent:
            if let managedOwner {
                removeLockIfOwned(
                    profileID: profileID,
                    ownerToken: managedOwner
                )
            } else if let externalLock {
                removeLockIfMatches(
                    externalLock,
                    profileID: profileID,
                    at: lockURL
                )
            }
        case .found, .unknown:
            registerRecovery(
                profileID: profileID,
                lockURL: lockURL,
                expectedBrowserDataDirectory: browserDataDirectory,
                removableSnapshot: removableSnapshot,
                blockingManagerPID: nil,
                message:
                    "Основной процесс браузера завершён, но его вспомогательные процессы ещё используют данные профиля. Профиль разблокируется автоматически после их завершения."
            )
        }
    }

    private func currentLeaseSnapshot(
        profileID: UUID,
        managedOwner: UUID?,
        externalLock: BrowserProcessLock?
    ) -> Data? {
        let lockURL = paths.lockFile(for: profileID)
        return try? paths.withProcessLockGuard(for: profileID) {
            guard try paths.privateFileEntryKind(lockURL) == .regular,
                  let data = try? Data(contentsOf: lockURL),
                  let current = try? Self.decodeLock(data)
            else {
                return nil
            }
            if let managedOwner {
                return current.ownerToken == managedOwner ? data : nil
            }
            if let externalLock {
                return current == externalLock ? data : nil
            }
            return nil
        }
    }

    private nonisolated static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func observeExternalProcess(
        profileID: UUID,
        lock: BrowserProcessLock
    ) {
        externalObservationTasks[profileID]?.cancel()
        guard passiveObservationsEnabled else {
            externalObservationTasks.removeValue(forKey: profileID)
            return
        }
        externalObservationTasks[profileID] = Task {
            [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: observationIntervalNanoseconds
                    )
                } catch {
                    return
                }
                guard externalLocks[profileID] == lock else {
                    return
                }
                if !processLivenessValidator(lock.pid) {
                    handleTermination(
                        profileID: profileID,
                        process: nil
                    )
                    return
                }
            }
        }
    }

    private func registerRecovery(
        profileID: UUID,
        lockURL: URL,
        expectedBrowserDataDirectory: URL,
        removableSnapshot: Data?,
        blockingManagerPID: pid_t?,
        startingCreatedAt: Date? = nil,
        message: String
    ) {
        externalLocks.removeValue(forKey: profileID)
        externalUnverifiedProfileIDs.remove(profileID)
        recoveryProfileIDs.insert(profileID)
        runningProfileIDs.insert(profileID)
        let entryIdentity = try? paths.withProcessLockGuard(
            for: profileID
        ) {
            try paths.privateFileEntryIdentity(lockURL)
        }
        let record = BrowserProcessRecoveryRecord(
            lockURL: lockURL,
            expectedBrowserDataDirectory: expectedBrowserDataDirectory,
            removableSnapshot: removableSnapshot,
            blockingManagerPID: blockingManagerPID,
            startingCreatedAt: startingCreatedAt,
            message: message,
            entryIdentity: entryIdentity ?? nil
        )
        recoveryRecords[profileID] = record
        lastError = message
        if resolveRecoveryIfSafe(profileID: profileID, record: record) {
            return
        }
        observeRecovery(profileID: profileID, record: record)
    }

    private func observeRecovery(
        profileID: UUID,
        record: BrowserProcessRecoveryRecord
    ) {
        recoveryObservationTasks[profileID]?.cancel()
        guard passiveObservationsEnabled else {
            recoveryObservationTasks.removeValue(forKey: profileID)
            return
        }
        recoveryObservationTasks[profileID] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: observationIntervalNanoseconds
                    )
                } catch {
                    return
                }
                guard recoveryRecords[profileID] == record else {
                    return
                }
                if resolveRecoveryIfSafe(
                    profileID: profileID,
                    record: record
                ) {
                    return
                }
            }
        }
    }

    private func observeDeletionTombstone(profileID: UUID) {
        tombstoneObservationTasks[profileID]?.cancel()
        guard passiveObservationsEnabled else {
            tombstoneObservationTasks.removeValue(forKey: profileID)
            return
        }
        tombstoneObservationTasks[profileID] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: observationIntervalNanoseconds
                    )
                } catch {
                    return
                }
                let kind = try? self.paths.withProcessLockGuard(
                    for: profileID
                ) {
                    try self.paths.privateFileEntryKind(
                        self.paths.profileDeletionTombstone(
                            for: profileID
                        )
                    )
                }
                guard kind == .missing else {
                    continue
                }
                reconcileProfile(profileID: profileID)
                return
            }
        }
    }

    private func resolveRecoveryIfSafe(
        profileID: UUID,
        record: BrowserProcessRecoveryRecord
    ) -> Bool {
        switch recoveryEntryChange(
            profileID: profileID,
            record: record
        ) {
        case .changed:
            clearRecoveryState(profileID: profileID, record: record)
            reconcileProfile(profileID: profileID)
            return true
        case .missing:
            guard browserDataProcessInspector(
                record.expectedBrowserDataDirectory
            ) == .absent else {
                return false
            }
            clearRecoveryState(profileID: profileID, record: record)
            reconcileProfile(profileID: profileID)
            return true
        case .unsafe, .unavailable:
            return false
        case .unchanged:
            break
        }

        let startingAge = record.startingCreatedAt.map {
            now().timeIntervalSince($0)
        }
        if let managerPID = record.blockingManagerPID,
           processLivenessValidator(managerPID)
        {
            guard let startingAge else {
                return false
            }
            if startingAge < 0 ||
                startingAge < startingLeaseTimeout
            {
                return false
            }
        }
        guard browserDataProcessInspector(
            record.expectedBrowserDataDirectory
        ) == .absent else {
            return false
        }
        guard removeRecoveryEntryIfSafe(
            profileID: profileID,
            record: record
        ) else {
            return false
        }
        clearRecoveryState(profileID: profileID, record: record)
        return true
    }

    private func clearRecoveryState(
        profileID: UUID,
        record: BrowserProcessRecoveryRecord
    ) {
        recoveryObservationTasks[profileID]?.cancel()
        recoveryObservationTasks.removeValue(forKey: profileID)
        recoveryRecords.removeValue(forKey: profileID)
        recoveryProfileIDs.remove(profileID)
        if processes[profileID]?.isRunning != true,
           externalLocks[profileID] == nil
        {
            runningProfileIDs.remove(profileID)
        }
        if lastError == record.message {
            lastError = nil
        }
    }

    private func recoveryEntryChange(
        profileID: UUID,
        record: BrowserProcessRecoveryRecord
    ) -> BrowserRecoveryEntryChange {
        let readResult: BrowserLeaseReadResult
        do {
            readResult = try readLeaseEntry(
                profileID: profileID,
                lockURL: record.lockURL
            )
        } catch {
            return .unavailable
        }
        if readResult.identity != record.entryIdentity {
            return .changed
        }
        switch readResult.entry {
        case .missing:
            return .missing
        case .unsafe:
            return .unsafe
        case .unreadable:
            return .unavailable
        case let .data(data):
            guard let snapshot = record.removableSnapshot else {
                return .changed
            }
            return data == snapshot ? .unchanged : .changed
        }
    }

    private func removeRecoveryEntryIfSafe(
        profileID: UUID,
        record: BrowserProcessRecoveryRecord
    ) -> Bool {
        do {
            return try paths.withProcessLockGuard(for: profileID) {
                let entryKind = try paths.privateFileEntryKind(record.lockURL)
                switch entryKind {
                case .missing:
                    return true
                case .unsafe:
                    return false
                case .regular:
                    guard let snapshot = record.removableSnapshot else {
                        return false
                    }
                    return removeLockIfSnapshotMatchesWhileGuardHeld(
                        lockURL: record.lockURL,
                        snapshot: snapshot
                    )
                }
            }
        } catch {
            return false
        }
    }

    private func acquireLease(
        _ lock: BrowserProcessLock,
        profileID: UUID,
        at lockURL: URL,
        browserDataDirectory: URL
    ) throws {
        try paths.withProcessLockGuard(for: profileID) {
            switch try paths.privateFileEntryKind(
                paths.profileDeletionTombstone(for: profileID)
            ) {
            case .regular, .unsafe:
                throw BrowserProfileDeletedError()
            case .missing:
                break
            }
            switch try paths.privateFileEntryKind(lockURL) {
            case .regular, .unsafe:
                throw POSIXError(.EEXIST)
            case .missing:
                break
            }
            let inspection = browserDataProcessInspector(
                browserDataDirectory
            )
            guard inspection == .absent else {
                throw BrowserProfileLeaseUnavailableError(
                    inspection: inspection
                )
            }
            try paths.prepareProfileDirectories(for: profileID)
            try FileManager.default.createDirectory(
                at: browserDataDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: browserDataDirectory.path
            )
            try paths.createPrivateFileExclusively(
                Self.encodeLock(lock),
                at: lockURL
            )
        }
    }

    private func writeOwnedLease(
        _ lock: BrowserProcessLock,
        profileID: UUID,
        ownerToken: UUID,
        at lockURL: URL
    ) throws {
        try paths.withProcessLockGuard(for: profileID) {
            let currentData = try Data(contentsOf: lockURL)
            let current = try Self.decodeLock(currentData)
            guard current.ownerToken == ownerToken else {
                throw POSIXError(.EBUSY)
            }
            try paths.writePrivateFile(Self.encodeLock(lock), to: lockURL)
        }
    }

    private func removeLockIfOwned(
        profileID: UUID,
        ownerToken: UUID
    ) {
        let lockURL = paths.lockFile(for: profileID)
        do {
            try paths.withProcessLockGuard(for: profileID) {
                guard let data = try? Data(contentsOf: lockURL),
                      let lock = try? Self.decodeLock(data),
                      lock.ownerToken == ownerToken
                else {
                    return
                }
                _ = removeLockIfSnapshotMatchesWhileGuardHeld(
                    lockURL: lockURL,
                    snapshot: data
                )
            }
        } catch {
            return
        }
    }

    private func removeLockIfMatches(
        _ expected: BrowserProcessLock,
        profileID: UUID,
        at lockURL: URL
    ) {
        do {
            try paths.withProcessLockGuard(for: profileID) {
                guard let data = try? Data(contentsOf: lockURL),
                      let current = try? Self.decodeLock(data),
                      current == expected
                else {
                    return
                }
                _ = removeLockIfSnapshotMatchesWhileGuardHeld(
                    lockURL: lockURL,
                    snapshot: data
                )
            }
        } catch {
            return
        }
    }

    private func removeLockIfSnapshotMatches(
        profileID: UUID,
        lockURL: URL,
        snapshot: Data
    ) -> Bool {
        do {
            return try paths.withProcessLockGuard(for: profileID) {
                removeLockIfSnapshotMatchesWhileGuardHeld(
                    lockURL: lockURL,
                    snapshot: snapshot
                )
            }
        } catch {
            return false
        }
    }

    private func removeLockIfSnapshotMatchesWhileGuardHeld(
        lockURL: URL,
        snapshot: Data
    ) -> Bool {
        guard (try? paths.privateFileEntryKind(lockURL)) == .regular,
              let current = try? Data(contentsOf: lockURL),
              current == snapshot
        else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: lockURL)
            return true
        } catch {
            return false
        }
    }

    private func readLeaseEntry(
        profileID: UUID,
        lockURL: URL
    ) throws -> BrowserLeaseReadResult {
        try paths.withProcessLockGuard(for: profileID) {
            let entry = try readLeaseEntryWhileGuardHeld(lockURL: lockURL)
            let identity = try paths.privateFileEntryIdentity(lockURL)
            return BrowserLeaseReadResult(
                entry: entry,
                identity: identity
            )
        }
    }

    private func readLeaseEntryWhileGuardHeld(
        lockURL: URL
    ) throws -> BrowserLeaseEntrySnapshot {
        switch try paths.privateFileEntryKind(lockURL) {
        case .missing:
            return .missing
        case .unsafe:
            return .unsafe
        case .regular:
            do {
                return .data(try Data(contentsOf: lockURL))
            } catch {
                return .unreadable
            }
        }
    }

    private static func encodeLock(_ lock: BrowserProcessLock) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(lock)
    }

    private static func decodeLock(_ data: Data) throws -> BrowserProcessLock {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrowserProcessLock.self, from: data)
    }

    private static func isMissingPathError(_ error: Error) -> Bool {
        if let error = error as? POSIXError {
            return error.code == .ENOENT
        }
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            error.code == NSFileNoSuchFileError
    }

    private static func isExistingPathError(_ error: Error) -> Bool {
        if let error = error as? POSIXError {
            return error.code == .EEXIST
        }
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            error.code == NSFileWriteFileExistsError
    }

    private func prepareDiagnosticLog(_ url: URL) throws {
        try paths.validatePrivateFile(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            try paths.writePrivateFile(Data(), to: url)
            return
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        if let size = attributes[.size] as? NSNumber,
           size.intValue > 64_000 {
            try paths.writePrivateFile(Data(), to: url)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func appendDiagnostic(
        _ message: String,
        to url: URL
    ) throws {
        try prepareDiagnosticLog(url)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(timestamp) \(message)\n".utf8))
    }

    private nonisolated static func inspectProcess(
        _ lock: BrowserProcessLock
    ) -> BrowserProcessIdentityInspection {
        guard isProcessAlive(lock.pid) else {
            return .unrelated
        }
        guard let process = processArguments(pid: lock.pid) else {
            return .unknown
        }
        let expectedExecutable = URL(
            fileURLWithPath: lock.executablePath
        ).standardizedFileURL.path
        let observedExecutables = [
            process.executablePath,
            process.arguments.first
        ].compactMap { value in
            value.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        }
        guard observedExecutables.contains(expectedExecutable),
              process.arguments.contains(
                  "--user-data-dir=\(lock.browserDataPath)"
              )
        else {
            return .unrelated
        }
        return .expected
    }

    private nonisolated static func inspectBrowserDataProcess(
        _ browserDataDirectory: URL
    ) -> BrowserDataProcessInspection {
        guard let processIDs = sameUserProcessIDs() else {
            return .unknown
        }
        let expectedPath =
            browserDataDirectory.standardizedFileURL.path
        var inspectionWasUnavailable = false
        for pid in processIDs where pid != getpid() {
            guard let process = processArguments(pid: pid) else {
                if isProcessAlive(pid) {
                    inspectionWasUnavailable = true
                }
                continue
            }
            if arguments(
                process.arguments,
                useBrowserDataPath: expectedPath
            ) {
                return .found
            }
        }
        return inspectionWasUnavailable ? .unknown : .absent
    }

    nonisolated static func arguments(
        _ arguments: [String],
        useBrowserDataPath expectedPath: String
    ) -> Bool {
        let standardizedExpected = URL(
            fileURLWithPath: expectedPath
        ).standardizedFileURL.path
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--user-data-dir=") {
                let value = String(
                    argument.dropFirst("--user-data-dir=".count)
                )
                if URL(fileURLWithPath: value)
                    .standardizedFileURL.path == standardizedExpected
                {
                    return true
                }
            } else if argument == "--user-data-dir",
                      arguments.indices.contains(index + 1),
                      URL(fileURLWithPath: arguments[index + 1])
                        .standardizedFileURL.path == standardizedExpected
            {
                return true
            }
        }
        return false
    }

    private nonisolated static func sameUserProcessIDs() -> [pid_t]? {
        var managementInformationBase = [
            CTL_KERN,
            KERN_PROC,
            KERN_PROC_UID,
            Int32(getuid())
        ]
        var requiredBytes = 0
        guard managementInformationBase.withUnsafeMutableBufferPointer({
            sysctl(
                $0.baseAddress,
                u_int($0.count),
                nil,
                &requiredBytes,
                nil,
                0
            )
        }) == 0, requiredBytes > 0 else {
            return nil
        }

        let entrySize = MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](
            repeating: kinfo_proc(),
            count: requiredBytes / entrySize + 32
        )
        var actualBytes = entries.count * entrySize
        let readResult = managementInformationBase
            .withUnsafeMutableBufferPointer { base in
                entries.withUnsafeMutableBytes { bytes in
                    sysctl(
                        base.baseAddress,
                        u_int(base.count),
                        bytes.baseAddress,
                        &actualBytes,
                        nil,
                        0
                    )
                }
            }
        guard readResult == 0, actualBytes >= 0 else {
            return nil
        }
        return entries
            .prefix(actualBytes / entrySize)
            .map(\.kp_proc.p_pid)
    }

    private nonisolated static func processArguments(
        pid: pid_t
    ) -> (executablePath: String, arguments: [String])? {
        var argumentMaximum = Int32()
        var argumentMaximumSize = MemoryLayout<Int32>.size
        guard sysctlbyname(
            "kern.argmax",
            &argumentMaximum,
            &argumentMaximumSize,
            nil,
            0
        ) == 0, argumentMaximum > 0 else {
            return nil
        }

        var buffer = [UInt8](
            repeating: 0,
            count: Int(argumentMaximum)
        )
        var bufferSize = buffer.count
        var managementInformationBase = [
            CTL_KERN,
            KERN_PROCARGS2,
            pid
        ]
        let readResult = managementInformationBase
            .withUnsafeMutableBufferPointer { base in
                buffer.withUnsafeMutableBytes { bytes in
                    sysctl(
                        base.baseAddress,
                        u_int(base.count),
                        bytes.baseAddress,
                        &bufferSize,
                        nil,
                        0
                    )
                }
            }
        guard readResult == 0,
              bufferSize > MemoryLayout<Int32>.size
        else {
            return nil
        }
        buffer.removeSubrange(bufferSize..<buffer.count)

        var argumentCount = Int32()
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            destination.copyBytes(
                from: buffer.prefix(MemoryLayout<Int32>.size)
            )
        }
        guard argumentCount > 0 else {
            return nil
        }

        var index = MemoryLayout<Int32>.size
        guard let executablePath = readNullTerminatedString(
            buffer,
            index: &index
        ) else {
            return nil
        }
        while index < buffer.count, buffer[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0..<Int(argumentCount) {
            guard let argument = readNullTerminatedString(
                buffer,
                index: &index
            ) else {
                return nil
            }
            arguments.append(argument)
        }
        return (executablePath, arguments)
    }

    private nonisolated static func readNullTerminatedString(
        _ buffer: [UInt8],
        index: inout Int
    ) -> String? {
        guard index < buffer.count else {
            return nil
        }
        let start = index
        while index < buffer.count, buffer[index] != 0 {
            index += 1
        }
        guard index < buffer.count else {
            return nil
        }
        let value = String(decoding: buffer[start..<index], as: UTF8.self)
        index += 1
        return value
    }
}
