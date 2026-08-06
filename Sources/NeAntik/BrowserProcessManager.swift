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
    case checking
    case managed
    case externalVerified
    case externalManualOnly
    case externalUnverified
    case recoveryRequired

    var isRunning: Bool {
        self != .stopped
    }

    var canRequestStop: Bool {
        self != .checking &&
            self != .externalManualOnly &&
            self != .externalUnverified &&
            self != .recoveryRequired
    }

    var title: String {
        switch self {
        case .stopped:
            "Остановлен"
        case .checking:
            "Проверка…"
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
        case .checking:
            "NeAntik проверяет, свободны ли данные профиля. Дождись завершения проверки."
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
    private static let allowedInheritedEnvironmentKeys: Set<String> = [
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TMPDIR",
        "USER",
        "XPC_FLAGS",
        "XPC_SERVICE_NAME",
        "__CFBundleIdentifier"
    ]

    static func requiresProxyContextRetest(
        profile: BrowserProfile,
        now: Date = Date()
    ) -> Bool {
        guard profile.proxy != nil,
              profile.identity.timezoneIdentifier != nil ||
                profile.identity.localeIdentifier != nil
        else {
            return false
        }
        return profile.identity.proxyContextEvidence?.isFresh(
            relativeTo: now
        ) != true
    }

    private static let protectedAdditionalArgumentPrefixes = [
        "--user-data-dir",
        "--proxy-server",
        "--no-proxy-server",
        "--proxy-auto-detect",
        "--proxy-pac-url",
        "--proxy-bypass-list",
        "--host-resolver-rules",
        "--webrtc-ip-handling-policy",
        "--force-webrtc-ip-handling-policy",
        "--disable-quic",
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
        now: Date = Date(),
        purpose: BrowserLaunchPurpose = .normal
    ) -> [String] {
        var arguments = [
            "--user-data-dir=\(browserDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--new-window"
        ]
        var disabledFeatures = Set<String>()

        if runtimeCapabilities.contains(.fingerprintSeed) {
            arguments.append("--fingerprinting-client-rects-noise")
            arguments.append("--fingerprinting-canvas-measuretext-noise")
            arguments.append("--fingerprinting-canvas-image-data-noise")
            // The runtime normalizes WebGL but not the WebGPU adapter surface.
            // Keep WebGPU unavailable until it is part of the same reviewed
            // Apple device tuple.
            disabledFeatures.insert("WebGPUService")
        }
        let hasFreshProxyContext =
            profile.proxy != nil &&
            profile.identity.proxyContextEvidence?.isFresh(
                relativeTo: now
            ) == true
        if runtimeCapabilities.contains(.fingerprintSeed),
           hasFreshProxyContext,
           let locale = profile.identity.localeIdentifier {
            arguments.append("--lang=\(locale)")
            arguments.append("--accept-lang=\(locale)")
        }

        if let proxy = profile.proxy {
            arguments.append("--proxy-server=\(proxy.chromiumServer)")
            arguments.append(
                "--webrtc-ip-handling-policy=disable_non_proxied_udp"
            )
            arguments.append("--disable-quic")
            // Resolver rules are the primary fail-closed control. Disabling
            // Chromium's asynchronous resolver and automatic DoH upgrade add
            // defense in depth so a future resolver path cannot silently
            // bypass them.
            disabledFeatures.formUnion(["AsyncDns", "DnsOverHttpsUpgrade"])
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
                "--webrtc-ip-handling-policy=default_public_interface_only"
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

    static func environment(
        profile: BrowserProfile,
        runtimeCapabilities: BrowserRuntimeCapabilities = [],
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> [String: String] {
        var environment = inherited.filter {
            allowedInheritedEnvironmentKeys.contains($0.key)
        }

        guard runtimeCapabilities.contains(.fingerprintSeed) else {
            return environment
        }
        environment["NEANTIK_PROFILE_SEED"] =
            String(profile.identity.runtimeSeed)

        let hasFreshProxyContext =
            profile.proxy != nil &&
            profile.identity.proxyContextEvidence?.isFresh(
                relativeTo: now
            ) == true
        if hasFreshProxyContext,
           let timezone = profile.identity.timezoneIdentifier {
            environment["NEANTIK_PROFILE_TIMEZONE"] = timezone
        }
        return environment
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

private enum BrowserLeaseEntryInventoryAnchor: Equatable, Sendable {
    case missing
    case present(PrivateFileEntryIdentity)
    case unavailable
}

private enum BrowserStartingOwnerInventoryAnchor:
    Equatable, Sendable
{
    case notApplicable
    case alive(pid_t)
    case dead(pid_t)
    case unavailable
}

private struct BrowserLeaseInventoryAnchor: Equatable, Sendable {
    let entry: BrowserLeaseEntryInventoryAnchor
    let startingOwner: BrowserStartingOwnerInventoryAnchor

    static let unavailable = BrowserLeaseInventoryAnchor(
        entry: .unavailable,
        startingOwner: .unavailable
    )
}

private struct BrowserProcessReconcileEvidence: Sendable {
    let leaseAnchors: [UUID: BrowserLeaseInventoryAnchor]
    let inventory: BrowserProcessInventory
}

private struct BrowserLeaseAnchorValidation {
    var matchingProfileIDs = Set<UUID>()
    var changedProfileIDs = Set<UUID>()
    var unavailableProfileIDs = Set<UUID>()

    var isClean: Bool {
        changedProfileIDs.isEmpty &&
            unavailableProfileIDs.isEmpty
    }
}

private struct QueuedBrowserReconcile {
    let profiles: [BrowserProfile]
    let retryCount: Int
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
    private let processInventoryProvider:
        (@Sendable () -> BrowserProcessInventory)?
    private let processSignaler: (pid_t, Int32) -> Int32
    private let managedProcessTerminator: (Process) -> Void
    private let allowsExternalProcessSignaling: Bool
    private let observationIntervalNanoseconds: UInt64
    private let startingLeaseTimeout: TimeInterval
    private let now: () -> Date
    private var processes: [UUID: Process] = [:]
    private var managedLeaseOwners: [UUID: UUID] = [:]
    private var managedBrowserDataDirectories: [UUID: URL] = [:]
    private var transientEmptyProfileDirectoryIDs = Set<UUID>()
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
    private var reconcileTask: Task<Void, Never>?
    private var reconcileGeneration: UInt64 = 0
    private var queuedReconcile: QueuedBrowserReconcile?
    private var lastReconciledProfiles: [BrowserProfile] = []
    private var pendingReconciliationProfileIDs = Set<UUID>()
    private var passiveInventoryObservationTask: Task<Void, Never>?
    private var reservedFingerprintAuditDataDirectories = Set<String>()

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
        let provider = DarwinBrowserProcessInventoryProvider()
        let coordinator = BrowserProcessInventoryCaptureCoordinator {
            provider.capture()
        }
        self.processInventoryProvider = {
            coordinator.capture()
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
        self.processInventoryProvider = nil
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
        processInventoryProvider:
            (@Sendable () -> BrowserProcessInventory)? = nil,
        allowsExternalProcessSignaling: Bool = true,
        startingLeaseTimeout: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.paths = paths
        self.processIdentityInspector = processIdentityInspector
        self.processLivenessValidator = processLivenessValidator
        self.browserDataProcessInspector = browserDataProcessInspector
        if let processInventoryProvider {
            let coordinator =
                BrowserProcessInventoryCaptureCoordinator(
                    provider: processInventoryProvider
                )
            self.processInventoryProvider = {
                coordinator.capture()
            }
        } else {
            self.processInventoryProvider = nil
        }
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
        lastReconciledProfiles = profiles
        if profiles.isEmpty {
            reconcileGeneration &+= 1
            reconcileTask?.cancel()
            queuedReconcile = nil
            reconcile(
                profiles: [],
                processIdentityInspector: { _ in .unknown },
                browserDataProcessInspector: { _ in .unknown },
                expectedLeaseAnchors: [:]
            )
            return
        }
        guard let processInventoryProvider else {
            reconcile(
                profiles: profiles,
                processIdentityInspector: processIdentityInspector,
                browserDataProcessInspector: browserDataProcessInspector,
                expectedLeaseAnchors: [:]
            )
            return
        }

        reconcileGeneration &+= 1
        passiveObservationsEnabled = true
        cancelPassiveObservationTasks()
        let profileIDs = Set(profiles.map(\.id))
        pendingReconciliationProfileIDs.formUnion(profileIDs)
        runningProfileIDs.formUnion(profileIDs)
        if reconcileTask != nil {
            queuedReconcile = QueuedBrowserReconcile(
                profiles: profiles,
                retryCount: 0
            )
            return
        }
        startInventoryReconcile(
            profiles: profiles,
            generation: reconcileGeneration,
            retryCount: 0,
            processInventoryProvider: processInventoryProvider
        )
    }

    func reserveFingerprintAuditDataDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "app.neantik.fingerprint-audit",
                isDirectory: true
            )
        for _ in 0..<8 {
            let directory = root.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            do {
                try paths.createPrivateDirectoryExclusively(directory)
                reservedFingerprintAuditDataDirectories.insert(
                    directory.standardizedFileURL.path
                )
                return directory
            } catch let error as POSIXError
                where error.code == .EEXIST
            {
                continue
            }
        }
        throw NeAntikError.fingerprintAuditFailed(
            "Не удалось безопасно подготовить временные данные браузера."
        )
    }

    private func startInventoryReconcile(
        profiles: [BrowserProfile],
        generation: UInt64,
        retryCount: Int,
        processInventoryProvider:
            @escaping @Sendable () -> BrowserProcessInventory
    ) {
        let paths = paths
        let profileIDs = profiles.map(\.id)
        reconcileTask = Task { [weak self] in
            let evidence = await Task.detached(priority: .utility) {
                Self.captureReconcileEvidence(
                    paths: paths,
                    profileIDs: profileIDs,
                    processInventoryProvider:
                        processInventoryProvider
                )
            }.value
            guard let self else {
                return
            }
            reconcileTask = nil
            let anchorValidation =
                leaseAnchorValidation(evidence.leaseAnchors)
            if !Task.isCancelled,
               generation == reconcileGeneration,
               passiveObservationsEnabled,
               anchorValidation.isClean {
                reconcile(
                    profiles: profiles,
                    processIdentityInspector:
                        evidence.inventory.inspectProcess,
                    browserDataProcessInspector:
                        evidence.inventory.inspectBrowserDataProcess,
                    expectedLeaseAnchors: evidence.leaseAnchors
                )
            } else if passiveObservationsEnabled,
                      generation == reconcileGeneration {
                if anchorValidation.unavailableProfileIDs.isEmpty,
                   !anchorValidation.changedProfileIDs.isEmpty,
                   retryCount < 2
                {
                    reconcileGeneration &+= 1
                    queuedReconcile = QueuedBrowserReconcile(
                        profiles: profiles,
                        retryCount: retryCount + 1
                    )
                } else if !anchorValidation.isClean {
                    let stableProfiles = profiles.filter {
                        anchorValidation.matchingProfileIDs
                            .contains($0.id)
                    }
                    reconcile(
                        profiles: stableProfiles,
                        processIdentityInspector:
                            evidence.inventory.inspectProcess,
                        browserDataProcessInspector:
                            evidence.inventory
                                .inspectBrowserDataProcess,
                        expectedLeaseAnchors:
                            evidence.leaseAnchors.filter {
                                anchorValidation
                                    .matchingProfileIDs
                                    .contains($0.key)
                            }
                    )
                    let blockedProfileIDs =
                        anchorValidation.changedProfileIDs.union(
                            anchorValidation
                                .unavailableProfileIDs
                        )
                    markReconciliationUnavailable(
                        profiles: profiles.filter {
                            blockedProfileIDs.contains($0.id)
                        }
                    )
                }
            }
            startQueuedInventoryReconcileIfNeeded(
                processInventoryProvider: processInventoryProvider
            )
        }
    }

    private func startQueuedInventoryReconcileIfNeeded(
        processInventoryProvider:
            @escaping @Sendable () -> BrowserProcessInventory
    ) {
        guard reconcileTask == nil,
              passiveObservationsEnabled,
              let queued = queuedReconcile
        else {
            return
        }
        queuedReconcile = nil
        startInventoryReconcile(
            profiles: queued.profiles,
            generation: reconcileGeneration,
            retryCount: queued.retryCount,
            processInventoryProvider: processInventoryProvider
        )
    }

    private func reconcile(
        profiles: [BrowserProfile],
        processIdentityInspector:
            (BrowserProcessLock) -> BrowserProcessIdentityInspection,
        browserDataProcessInspector: @escaping
            (URL) -> BrowserDataProcessInspection,
        expectedLeaseAnchors:
            [UUID: BrowserLeaseInventoryAnchor]
    ) {
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
        pendingReconciliationProfileIDs.removeAll()
        runningProfileIDs = Set(
            processes.compactMap { key, process in
                process.isRunning ? key : nil
            }
        )

        for profile in profiles {
            reconcileProfile(
                profileID: profile.id,
                processIdentityInspector: processIdentityInspector,
                browserDataProcessInspector:
                    browserDataProcessInspector,
                expectedLeaseAnchor:
                    expectedLeaseAnchors[profile.id]
            )
        }
    }

    func suspendPassiveObservations() {
        passiveObservationsEnabled = false
        reconcileGeneration &+= 1
        reconcileTask?.cancel()
        queuedReconcile = nil
        cancelPassiveObservationTasks()
    }

    private func cancelPassiveObservationTasks() {
        externalObservationTasks.values.forEach { $0.cancel() }
        externalObservationTasks.removeAll()
        recoveryObservationTasks.values.forEach { $0.cancel() }
        recoveryObservationTasks.removeAll()
        tombstoneObservationTasks.values.forEach { $0.cancel() }
        tombstoneObservationTasks.removeAll()
        passiveInventoryObservationTask?.cancel()
        passiveInventoryObservationTask = nil
    }

    nonisolated private static func captureReconcileEvidence(
        paths: AppPaths,
        profileIDs: [UUID],
        processInventoryProvider:
            @Sendable () -> BrowserProcessInventory
    ) -> BrowserProcessReconcileEvidence {
        var anchors: [UUID: BrowserLeaseInventoryAnchor] = [:]
        anchors.reserveCapacity(profileIDs.count)
        for profileID in profileIDs {
            anchors[profileID] = captureLeaseAnchor(
                paths: paths,
                profileID: profileID
            )
        }
        return BrowserProcessReconcileEvidence(
            leaseAnchors: anchors,
            inventory: processInventoryProvider()
        )
    }

    private func leaseAnchorValidation(
        _ expected: [UUID: BrowserLeaseInventoryAnchor]
    ) -> BrowserLeaseAnchorValidation {
        var validation = BrowserLeaseAnchorValidation()
        for (profileID, anchor) in expected {
            guard anchor != BrowserLeaseInventoryAnchor.unavailable else {
                validation.unavailableProfileIDs.insert(profileID)
                continue
            }
            let current = Self.captureLeaseAnchor(
                paths: paths,
                profileID: profileID
            )
            guard current != BrowserLeaseInventoryAnchor.unavailable else {
                validation.unavailableProfileIDs.insert(profileID)
                continue
            }
            guard current == anchor else {
                validation.changedProfileIDs.insert(profileID)
                continue
            }
            validation.matchingProfileIDs.insert(profileID)
        }
        return validation
    }

    private func markReconciliationUnavailable(
        profiles: [BrowserProfile]
    ) {
        let profileIDs = Set(profiles.map(\.id))
        pendingReconciliationProfileIDs.subtract(profileIDs)
        recoveryProfileIDs.formUnion(profileIDs)
        runningProfileIDs.formUnion(profileIDs)
        lastError =
            "NeAntik не смог безопасно проверить файлы запуска. Профили остаются заблокированными; проверь доступ к папке данных и повтори попытку."
    }

    nonisolated private static func captureLeaseAnchor(
        paths: AppPaths,
        profileID: UUID
    ) -> BrowserLeaseInventoryAnchor {
        do {
            return try paths.withProcessLockGuard(for: profileID) {
                let lockURL = paths.lockFile(for: profileID)
                let identity = try paths.privateFileEntryIdentity(
                    lockURL
                )
                let entry: BrowserLeaseEntryInventoryAnchor =
                    identity.map { .present($0) } ?? .missing
                guard identity != nil,
                      try paths.privateFileEntryKind(lockURL) == .regular,
                      let data = try? Data(contentsOf: lockURL),
                      let lock = try? decodeLock(data),
                      lock.phase == .starting,
                      let managerPID = lock.managerPID,
                      managerPID > 0
                else {
                    return BrowserLeaseInventoryAnchor(
                        entry: entry,
                        startingOwner: .notApplicable
                    )
                }
                return BrowserLeaseInventoryAnchor(
                    entry: entry,
                    startingOwner:
                        isProcessAlive(managerPID)
                            ? .alive(managerPID)
                            : .dead(managerPID)
                )
            }
        } catch {
            return .unavailable
        }
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
        if pendingReconciliationProfileIDs.contains(profileID) {
            return .checking
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
        reconcileProfile(
            profileID: profileID,
            processIdentityInspector: processIdentityInspector,
            browserDataProcessInspector: browserDataProcessInspector,
            expectedLeaseAnchor: nil
        )
    }

    private func reconcileProfile(
        profileID: UUID,
        processIdentityInspector:
            (BrowserProcessLock) -> BrowserProcessIdentityInspection,
        browserDataProcessInspector: @escaping
            (URL) -> BrowserDataProcessInspection,
        expectedLeaseAnchor: BrowserLeaseInventoryAnchor?
    ) {
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
                browserDataProcessInspector:
                    browserDataProcessInspector,
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
                browserDataProcessInspector:
                    browserDataProcessInspector,
                message:
                    "Файл состояния запуска недоступен. Профиль заблокирован до безопасной проверки."
            )
            return
        }
        if let expectedLeaseAnchor {
            let observedEntry = readResult.identity.map {
                BrowserLeaseEntryInventoryAnchor.present($0)
            } ?? .missing
            guard observedEntry == expectedLeaseAnchor.entry else {
                recoveryProfileIDs.insert(profileID)
                runningProfileIDs.insert(profileID)
                lastError =
                    "Файл состояния запуска изменился во время проверки. Повторный запуск заблокирован; вернись в NeAntik и повтори проверку."
                return
            }
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
                browserDataProcessInspector:
                    browserDataProcessInspector,
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
                browserDataProcessInspector:
                    browserDataProcessInspector,
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
                browserDataProcessInspector:
                    browserDataProcessInspector,
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
                browserDataProcessInspector:
                    browserDataProcessInspector,
                message:
                    "Файл состояния запуска не соответствует этому профилю. Профиль остаётся заблокированным для защиты данных."
            )
            return
        }

        if lock.phase == .starting {
            if case .alive = expectedLeaseAnchor?.startingOwner {
                registerRecovery(
                    profileID: profileID,
                    lockURL: lockURL,
                    expectedBrowserDataDirectory:
                        browserDataDirectory,
                    removableSnapshot: data,
                    blockingManagerPID: lock.managerPID,
                    startingCreatedAt: lock.createdAt,
                    browserDataProcessInspector:
                        browserDataProcessInspector,
                    deferInitialResolution: true,
                    message:
                        "Другой экземпляр NeAntik ещё запускает этот профиль. Повторный запуск заблокирован."
                )
                return
            }
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
                browserDataProcessInspector:
                    browserDataProcessInspector,
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
                browserDataProcessInspector:
                    browserDataProcessInspector,
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
                    snapshot: data,
                    expectedIdentity: readResult.identity
                ) {
                    registerRecovery(
                        profileID: profileID,
                        lockURL: lockURL,
                        expectedBrowserDataDirectory: browserDataDirectory,
                        removableSnapshot: data,
                        blockingManagerPID: nil,
                        browserDataProcessInspector:
                            browserDataProcessInspector,
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
                    browserDataProcessInspector:
                        browserDataProcessInspector,
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
        guard !BrowserLaunchBuilder.requiresProxyContextRetest(
            profile: profile
        ) else {
            throw NeAntikError.proxyContextNeedsRetest
        }

        let browserDataDirectory =
            browserDataDirectoryOverride ??
            paths.browserDataDirectory(for: profile.id)
        let ownsFreshFingerprintAuditDirectory: Bool
        switch purpose {
        case .normal:
            ownsFreshFingerprintAuditDirectory = false
        case .fingerprintAudit:
            guard let browserDataDirectoryOverride else {
                throw NeAntikError.fingerprintAuditFailed(
                    "Для проверки не подготовлен временный каталог браузера."
                )
            }
            ownsFreshFingerprintAuditDirectory =
                reservedFingerprintAuditDataDirectories.remove(
                    browserDataDirectoryOverride.standardizedFileURL.path
                ) != nil
            guard ownsFreshFingerprintAuditDirectory else {
                throw NeAntikError.fingerprintAuditFailed(
                    "Временный каталог проверки не принадлежит этому запуску."
                )
            }
        }
        let profileDirectoryExistedBeforeLaunch =
            FileManager.default.fileExists(
                atPath: paths.profileDirectory(for: profile.id).path
            )

        let logURL = paths.logFile(for: profile.id)

        let process = Process()
        let launchNow = Date()
        process.executableURL = runtime.executableURL
        process.arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: browserDataDirectory,
            runtimeCapabilities: runtime.capabilities,
            additionalArguments: additionalArguments,
            startURLOverride: startURLOverride,
            now: launchNow,
            purpose: purpose
        )
        process.environment = BrowserLaunchBuilder.environment(
            profile: profile,
            runtimeCapabilities: runtime.capabilities,
            now: launchNow
        )
        process.currentDirectoryURL =
            browserDataDirectoryOverride == nil
                ? paths.profileDirectory(for: profile.id)
                : browserDataDirectory

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
                browserDataDirectory: browserDataDirectory,
                allowsUnknownBrowserDataInspection:
                    ownsFreshFingerprintAuditDirectory
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
                    browserDataDirectory: browserDataDirectory,
                    allowsUnknownBrowserDataInspection:
                        ownsFreshFingerprintAuditDirectory
                )
            } catch where Self.isExistingPathError(error) {
                reconcileProfile(profileID: profile.id)
                throw NeAntikError.profileAlreadyRunning
            } catch {
                throw NeAntikError.processLaunchFailed(
                    error.localizedDescription
                )
            }
        } catch let error as NeAntikError {
            throw error
        } catch {
            throw NeAntikError.processLaunchFailed(error.localizedDescription)
        }
        managedLeaseOwners[profile.id] = ownerToken
        managedBrowserDataDirectories[profile.id] = browserDataDirectory
        if browserDataDirectoryOverride != nil &&
            !profileDirectoryExistedBeforeLaunch {
            transientEmptyProfileDirectoryIDs.insert(profile.id)
        }

        do {
            try prepareDiagnosticLog(logURL)
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
            managedBrowserDataDirectories.removeValue(forKey: profile.id)
            removeLockIfOwned(
                profileID: profile.id,
                ownerToken: ownerToken
            )
            cleanupTransientProfileDirectoryIfSafe(profileID: profile.id)
            try? appendDiagnostic(
                "browser_launch_failed",
                to: logURL
            )
            throw NeAntikError.processLaunchFailed(error.localizedDescription)
        }
    }

    func stop(profileID: UUID) {
        if let process = processes[profileID] {
            if process.isRunning {
                managedProcessTerminator(process)
            } else {
                handleTermination(
                    profileID: profileID,
                    process: process
                )
            }
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
        if let process {
            guard let current = processes[profileID],
                  current === process
            else {
                return
            }
        }
        let managedOwner = managedLeaseOwners.removeValue(
            forKey: profileID
        )
        let externalLock = externalLocks[profileID]
        let lockURL = paths.lockFile(for: profileID)
        let browserDataDirectory =
            managedBrowserDataDirectories.removeValue(forKey: profileID) ??
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
                cleanupTransientProfileDirectoryIfSafe(
                    profileID: profileID
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
                surfaceMessage: false,
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
        DarwinBrowserProcessInventoryProvider.isProcessAlive(pid)
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
        browserDataProcessInspector:
            ((URL) -> BrowserDataProcessInspection)? = nil,
        deferInitialResolution: Bool = false,
        surfaceMessage: Bool = true,
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
        if surfaceMessage {
            lastError = message
        }
        let effectiveBrowserDataProcessInspector =
            browserDataProcessInspector ??
            self.browserDataProcessInspector
        if !deferInitialResolution {
            if resolveRecoveryIfSafe(
                profileID: profileID,
                record: record,
                browserDataProcessInspector:
                    effectiveBrowserDataProcessInspector
            ) {
                return
            }
        }
        observeRecovery(profileID: profileID, record: record)
    }

    private func observeRecovery(
        profileID: UUID,
        record: BrowserProcessRecoveryRecord
    ) {
        if processInventoryProvider != nil {
            recoveryObservationTasks[profileID]?.cancel()
            recoveryObservationTasks.removeValue(forKey: profileID)
            ensurePassiveInventoryObservation()
            return
        }
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

    private func ensurePassiveInventoryObservation() {
        guard passiveObservationsEnabled,
              passiveInventoryObservationTask == nil
        else {
            return
        }
        passiveInventoryObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?
                    .observationIntervalNanoseconds
                else {
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let processInventoryProvider =
                          self?.processInventoryProvider
                else {
                    return
                }
                guard let self else { return }
                let recordsBeforeCapture = Array(recoveryRecords)
                let ownerWasAlive = Dictionary(
                    uniqueKeysWithValues:
                        recordsBeforeCapture.compactMap {
                            profileID, record in
                            record.blockingManagerPID.map {
                                (
                                    profileID,
                                    self.processLivenessValidator($0)
                                )
                            }
                        }
                )
                let inventory = await Task.detached(priority: .utility) {
                    processInventoryProvider()
                }.value
                guard !Task.isCancelled,
                      passiveObservationsEnabled
                else {
                    return
                }
                let records = Array(recoveryRecords)
                guard !records.isEmpty else {
                    passiveInventoryObservationTask = nil
                    return
                }
                for (profileID, record) in records {
                    guard recoveryRecords[profileID] == record else {
                        continue
                    }
                    if let managerPID = record.blockingManagerPID {
                        guard ownerWasAlive[profileID] == false,
                              !processLivenessValidator(managerPID)
                        else {
                            continue
                        }
                    }
                    _ = resolveRecoveryIfSafe(
                        profileID: profileID,
                        record: record,
                        browserDataProcessInspector:
                            inventory.inspectBrowserDataProcess
                    )
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
        record: BrowserProcessRecoveryRecord,
        browserDataProcessInspector:
            ((URL) -> BrowserDataProcessInspection)? = nil
    ) -> Bool {
        let effectiveBrowserDataProcessInspector =
            browserDataProcessInspector ??
            self.browserDataProcessInspector
        switch recoveryEntryChange(
            profileID: profileID,
            record: record
        ) {
        case .changed:
            clearRecoveryState(profileID: profileID, record: record)
            if processInventoryProvider != nil {
                reconcile(profiles: lastReconciledProfiles)
            } else {
                reconcileProfile(profileID: profileID)
            }
            return true
        case .missing:
            guard effectiveBrowserDataProcessInspector(
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
        guard effectiveBrowserDataProcessInspector(
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
        if recoveryRecords.isEmpty {
            passiveInventoryObservationTask?.cancel()
            passiveInventoryObservationTask = nil
        }
        cleanupTransientProfileDirectoryIfSafe(profileID: profileID)
    }

    private func cleanupTransientProfileDirectoryIfSafe(
        profileID: UUID
    ) {
        guard transientEmptyProfileDirectoryIDs.contains(profileID)
        else {
            return
        }
        let directory = paths.profileDirectory(for: profileID)
        let lockURL = paths.lockFile(for: profileID)
        do {
            guard try paths.privateFileEntryKind(lockURL) == .missing,
                  FileManager.default.fileExists(atPath: directory.path),
                  try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                  ).isEmpty
            else {
                return
            }
            try FileManager.default.removeItem(at: directory)
            transientEmptyProfileDirectoryIDs.remove(profileID)
        } catch {
            // A non-empty or concurrently changed directory belongs to the
            // user. Leaving it is safer than attempting recursive cleanup.
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
        browserDataDirectory: URL,
        allowsUnknownBrowserDataInspection: Bool = false
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
            guard inspection == .absent ||
                    (
                        inspection == .unknown &&
                        allowsUnknownBrowserDataInspection
                    )
            else {
                throw BrowserProfileLeaseUnavailableError(
                    inspection: inspection
                )
            }
            let canonicalBrowserDataDirectory =
                paths.browserDataDirectory(for: profileID)
                    .standardizedFileURL
            if browserDataDirectory.standardizedFileURL ==
                canonicalBrowserDataDirectory {
                try paths.prepareProfileDirectories(for: profileID)
            }
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
        snapshot: Data,
        expectedIdentity: PrivateFileEntryIdentity?
    ) -> Bool {
        do {
            return try paths.withProcessLockGuard(for: profileID) {
                guard expectedIdentity != nil,
                      try paths.privateFileEntryIdentity(lockURL) ==
                        expectedIdentity
                else {
                    return false
                }
                return removeLockIfSnapshotMatchesWhileGuardHeld(
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

    nonisolated private static func decodeLock(
        _ data: Data
    ) throws -> BrowserProcessLock {
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
        DarwinBrowserProcessInventoryProvider()
            .capture()
            .inspectProcess(lock)
    }

    private nonisolated static func inspectBrowserDataProcess(
        _ browserDataDirectory: URL
    ) -> BrowserDataProcessInspection {
        DarwinBrowserProcessInventoryProvider()
            .capture()
            .inspectBrowserDataProcess(browserDataDirectory)
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

}
