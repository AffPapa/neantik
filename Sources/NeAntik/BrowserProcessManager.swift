import Combine
import Darwin
import Foundation

struct BrowserProcessLock: Codable, Equatable, Sendable {
    let pid: pid_t
    let executablePath: String
    let browserDataPath: String
    let createdAt: Date
}

enum BrowserProcessIdentityInspection: Equatable, Sendable {
    case expected
    case unrelated
    case unknown
}

enum BrowserLaunchBuilder {
    private static let protectedAdditionalArgumentPrefixes = [
        "--user-data-dir",
        "--proxy-server",
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
        startURLOverride: URL? = nil
    ) -> [String] {
        var arguments = [
            "--user-data-dir=\(browserDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-mode",
            "--new-window"
        ]

        if runtimeCapabilities.contains(.fingerprintSeed) {
            arguments.append("--fingerprint=\(profile.identity.runtimeSeed)")
            arguments.append("--fingerprinting-client-rects-noise")
            arguments.append("--fingerprinting-canvas-measuretext-noise")
            arguments.append("--fingerprinting-canvas-image-data-noise")
            // The 144 runtime normalizes WebGL but not WebGPU adapter
            // capabilities. Disable WebGPU in fingerprint mode so sites
            // cannot correlate the selected Apple tuple with the host GPU.
            arguments.append("--disable-features=WebGPUService")
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
            arguments.append(
                "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE \(proxy.host)"
            )
            arguments.append("--proxy-bypass-list=<-loopback>")
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

@MainActor
final class BrowserProcessManager: ObservableObject {
    @Published private(set) var runningProfileIDs = Set<UUID>()
    @Published var lastError: String?

    private let paths: AppPaths
    private let processIdentityInspector:
        (BrowserProcessLock) -> BrowserProcessIdentityInspection
    private let processLivenessValidator: (pid_t) -> Bool
    private let processSignaler: (pid_t, Int32) -> Int32
    private let managedProcessTerminator: (Process) -> Void
    private let observationIntervalNanoseconds: UInt64
    private var processes: [UUID: Process] = [:]
    private var externalLocks: [UUID: BrowserProcessLock] = [:]
    private var externalStopTasks: [UUID: Task<Void, Never>] = [:]
    private var externalObservationTasks: [UUID: Task<Void, Never>] = [:]

    init(paths: AppPaths) {
        self.paths = paths
        self.processIdentityInspector = {
            BrowserProcessManager.inspectProcess($0)
        }
        self.processLivenessValidator = {
            BrowserProcessManager.isProcessAlive($0)
        }
        self.processSignaler = { Darwin.kill($0, $1) }
        self.managedProcessTerminator = { $0.terminate() }
        self.observationIntervalNanoseconds = 1_000_000_000
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
        observationIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.paths = paths
        self.processIdentityInspector = {
            processIdentityValidator($0) ? .expected : .unrelated
        }
        self.processLivenessValidator = processLivenessValidator
        self.processSignaler = processSignaler
        self.managedProcessTerminator = managedProcessTerminator
        self.observationIntervalNanoseconds =
            observationIntervalNanoseconds
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
        observationIntervalNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.paths = paths
        self.processIdentityInspector = processIdentityInspector
        self.processLivenessValidator = processLivenessValidator
        self.processSignaler = processSignaler
        self.managedProcessTerminator = managedProcessTerminator
        self.observationIntervalNanoseconds =
            observationIntervalNanoseconds
    }

    func reconcile(profiles: [BrowserProfile]) {
        externalStopTasks.values.forEach { $0.cancel() }
        externalStopTasks.removeAll()
        externalObservationTasks.values.forEach { $0.cancel() }
        externalObservationTasks.removeAll()
        externalLocks.removeAll()
        runningProfileIDs = Set(
            processes.compactMap { key, process in
                process.isRunning ? key : nil
            }
        )

        for profile in profiles {
            let profileDirectory = paths.profileDirectory(for: profile.id)
            let lockURL = paths.lockFile(for: profile.id)
            guard FileManager.default.fileExists(
                atPath: profileDirectory.path
            ) else {
                continue
            }
            do {
                try paths.validatePrivateDirectory(profileDirectory)
                try paths.validatePrivateFile(lockURL)
            } catch {
                lastError =
                    "Файлы профиля не прошли локальную проверку безопасности пути: \(error.localizedDescription)"
                continue
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: lockURL),
                  let lock = try? decoder.decode(
                      BrowserProcessLock.self,
                      from: data
                  )
            else {
                try? FileManager.default.removeItem(at: lockURL)
                continue
            }

            switch processIdentityInspector(lock) {
            case .expected:
                externalLocks[profile.id] = lock
                runningProfileIDs.insert(profile.id)
                observeExternalProcess(
                    profileID: profile.id,
                    lock: lock
                )
            case .unknown:
                externalLocks[profile.id] = lock
                runningProfileIDs.insert(profile.id)
                lastError =
                    "NeAntik не смог безопасно проверить уже запущенный браузер. Профиль остаётся заблокированным до завершения процесса."
                observeExternalProcess(
                    profileID: profile.id,
                    lock: lock
                )
            case .unrelated:
                try? FileManager.default.removeItem(at: lockURL)
            }
        }
    }

    func launch(
        profile: BrowserProfile,
        runtime: BrowserRuntime,
        additionalArguments: [String] = [],
        startURLOverride: URL? = nil,
        browserDataDirectoryOverride: URL? = nil
    ) throws {
        guard !runningProfileIDs.contains(profile.id) else {
            throw NeAntikError.profileAlreadyRunning
        }
        guard profile.proxy?.isValid != false else {
            throw NeAntikError.invalidProxy
        }

        try paths.prepareProfileDirectories(for: profile.id)
        let browserDataDirectory =
            browserDataDirectoryOverride ??
            paths.browserDataDirectory(for: profile.id)
        try FileManager.default.createDirectory(
            at: browserDataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: browserDataDirectory.path
        )

        let logURL = paths.logFile(for: profile.id)
        try prepareDiagnosticLog(logURL)

        let process = Process()
        process.executableURL = runtime.executableURL
        process.arguments = BrowserLaunchBuilder.arguments(
            profile: profile,
            browserDataDirectory: browserDataDirectory,
            runtimeCapabilities: runtime.capabilities,
            additionalArguments: additionalArguments,
            startURLOverride: startURLOverride
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
                createdAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try paths.writePrivateFile(
                encoder.encode(lock),
                to: paths.lockFile(for: profile.id)
            )
        } catch {
            if process.isRunning {
                managedProcessTerminator(process)
            }
            if process.isRunning {
                processes[profile.id] = process
                runningProfileIDs.insert(profile.id)
                try? FileManager.default.removeItem(
                    at: paths.lockFile(for: profile.id)
                )
                throw NeAntikError.processLaunchFailed(
                    error.localizedDescription
                )
            }
            processes.removeValue(forKey: profile.id)
            runningProfileIDs.remove(profile.id)
            try? FileManager.default.removeItem(
                at: paths.lockFile(for: profile.id)
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
        if let lock = externalLocks[profileID] {
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
        processes.removeValue(forKey: profileID)
        externalStopTasks[profileID]?.cancel()
        externalStopTasks.removeValue(forKey: profileID)
        externalObservationTasks[profileID]?.cancel()
        externalObservationTasks.removeValue(forKey: profileID)
        externalLocks.removeValue(forKey: profileID)
        runningProfileIDs.remove(profileID)
        try? FileManager.default.removeItem(at: paths.lockFile(for: profileID))
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

    private static func inspectProcess(
        _ lock: BrowserProcessLock
    ) -> BrowserProcessIdentityInspection {
        guard isProcessAlive(lock.pid) else {
            return .unrelated
        }
        guard let commandLine = processCommandLine(pid: lock.pid) else {
            return .unknown
        }
        return commandLine.contains(lock.executablePath) &&
            commandLine.contains(
                "--user-data-dir=\(lock.browserDataPath)"
            )
            ? .expected
            : .unrelated
    }

    private static func processCommandLine(pid: pid_t) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = [
            "-ww",
            "-p", String(pid),
            "-o", "command="
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        } catch {
            return nil
        }
    }
}
