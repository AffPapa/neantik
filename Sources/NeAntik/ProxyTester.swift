import Darwin
import Foundation

struct ProxyTestResult: Equatable, Sendable {
    let ipAddress: String
    let city: String?
    let countryName: String?
    let countryCode: String?
    let timezoneIdentifier: String?
    let localeIdentifier: String?

    var locationSummary: String {
        [city, countryName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct ProxyTestObservation: Equatable, Sendable {
    let observedAt: Date
    let responseTimeMilliseconds: Int
    let result: ProxyTestResult
}

struct ProxyProbeError: LocalizedError, Equatable, Sendable {
    let outcome: ProxyHealthOutcome

    var errorDescription: String? {
        outcome.userSummary
    }
}

struct ProxyProcessResult: Sendable {
    let status: Int32
    let output: Data
    let outputExceeded: Bool
}

struct ProxyTester: Sendable {
    static let maximumResponseBytes = 16_384
    static let maximumProbeOutputBytes = maximumResponseBytes + 256
    static let metricsPrefix = "\nNEANTIK_METRICS_V1:"
    private static let invalidResponseMessage =
        "IP-сервис вернул некорректный ответ."

    static let curlArguments = [
        "--disable",
        "--silent",
        "--show-error",
        "--fail",
        "--max-time", "12",
        "--max-filesize", "\(maximumResponseBytes)",
        "--noproxy", "",
        "--config", "-",
        "--write-out", "\nNEANTIK_METRICS_V1:%{time_starttransfer}\n",
        "https://ipapi.co/json/"
    ]

    static func sanitizedProcessEnvironment(
        inherited _: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
    }

    func test(
        configuration: ProxyConfiguration,
        password: String
    ) async throws -> ProxyTestResult {
        do {
            return try await probe(
                configuration: configuration,
                password: password
            ).result
        } catch let error as ProxyProbeError {
            if error.outcome == .invalidConfiguration {
                throw NeAntikError.invalidProxy
            }
            throw NeAntikError.proxyTestFailed(
                error.localizedDescription
            )
        }
    }

    func probe(
        configuration: ProxyConfiguration,
        password: String,
        observedAt: @Sendable () -> Date = { Date() }
    ) async throws -> ProxyTestObservation {
        guard configuration.isValid else {
            throw ProxyProbeError(outcome: .invalidConfiguration)
        }
        guard Self.isValidPassword(password) else {
            throw ProxyProbeError(outcome: .invalidConfiguration)
        }

        var config =
            "proxy = \"\(Self.escaped(configuration.curlServer))\"\n"
        if !configuration.username.isEmpty {
            let credentials = "\(configuration.username):\(password)"
            config +=
                "proxy-user = \"\(Self.escaped(credentials))\"\n"
        }
        let inputData = Data(config.utf8)
        config.removeAll(keepingCapacity: false)
        let result: ProxyProcessResult
        do {
            result = try await Self.runCancellableProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: Self.curlArguments,
                standardInput: inputData,
                maximumOutputBytes: Self.maximumProbeOutputBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProxyProbeError(outcome: .internalFailure)
        }
        guard !result.outputExceeded else {
            throw ProxyProbeError(outcome: .invalidResponse)
        }
        guard result.status == 0 else {
            throw ProxyProbeError(
                outcome: Self.outcome(forCurlStatus: result.status)
            )
        }

        do {
            let parsed = try Self.parseProbeOutput(result.output)
        return ProxyTestObservation(
                observedAt: observedAt(),
                responseTimeMilliseconds: parsed.responseTimeMilliseconds,
                result: parsed.result
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProxyProbeError(outcome: .invalidResponse)
        }
    }

    static func isValidPassword(_ value: String) -> Bool {
        ProxyImportParser.passwordIsWithinLimits(value) &&
            !value.contains("\0")
    }

    static func outcome(forCurlStatus status: Int32) -> ProxyHealthOutcome {
        switch status {
        case 5, 6:
            .nameResolutionFailed
        case 28:
            .timedOut
        case 7:
            .connectionFailed
        case 67:
            .authenticationRejected
        case 35, 51, 58, 59, 60, 77, 80, 82, 83, 90, 91:
            .transportSecurityFailed
        case 52, 55, 56, 97:
            .protocolFailed
        case 22:
            .probeServiceFailed
        default:
            .connectionFailed
        }
    }

    static func parseProbeOutput(
        _ data: Data
    ) throws -> (
        result: ProxyTestResult,
        responseTimeMilliseconds: Int
    ) {
        guard data.count <= maximumProbeOutputBytes,
              let text = String(data: data, encoding: .utf8),
              let marker = text.range(
                of: metricsPrefix,
                options: .backwards
              )
        else {
            throw NeAntikError.proxyTestFailed(invalidResponseMessage)
        }
        let bodyText = String(text[..<marker.lowerBound])
        let metricText = text[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !metricText.isEmpty,
              metricText.utf8.count <= 64,
              let seconds = Double(metricText),
              seconds.isFinite,
              seconds >= 0,
              seconds <= 120
        else {
            throw NeAntikError.proxyTestFailed(invalidResponseMessage)
        }
        let milliseconds = Int((seconds * 1_000).rounded())
        guard (0...ProxyHealthAttempt.maximumResponseTimeMilliseconds)
            .contains(milliseconds)
        else {
            throw NeAntikError.proxyTestFailed(invalidResponseMessage)
        }
        return (
            try parseResponse(Data(bodyText.utf8)),
            milliseconds
        )
    }

    static func runCancellableProcess(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        maximumOutputBytes: Int = maximumResponseBytes
    ) async throws -> ProxyProcessResult {
        let runner = CancellableProcessRunner(
            executableURL: executableURL,
            arguments: arguments,
            environment: Self.sanitizedProcessEnvironment()
        )
        let boundedOutput = BoundedProcessOutput(
            maximumBytes: maximumOutputBytes
        )
        let completion = ProcessOutputCompletion()
        let input = Pipe()
        let output = Pipe()
        runner.process.standardInput = input
        runner.process.standardOutput = output
        runner.process.standardError = FileHandle.nullDevice

        input.fileHandleForWriting.write(standardInput)
        try input.fileHandleForWriting.close()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                continuation in
                completion.install(continuation)
                runner.process.terminationHandler = { process in
                    completion.processTerminated(
                        status: process.terminationStatus
                    )
                }
                do {
                    try runner.start()
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            while let chunk = try output
                                .fileHandleForReading
                                .read(upToCount: 4_096),
                                  !chunk.isEmpty {
                                if boundedOutput.append(chunk) {
                                    runner.stopForOutputLimit()
                                }
                            }
                            completion.readerFinished(
                                boundedOutput.snapshot()
                            )
                        } catch {
                            completion.fail(error)
                        }
                    }
                } catch {
                    completion.fail(error)
                }
            }
        } onCancel: {
            completion.markCancelled()
            runner.cancel()
        }
    }

    static func parseResponse(_ data: Data) throws -> ProxyTestResult {
        guard data.count <= maximumResponseBytes else {
            throw NeAntikError.proxyTestFailed(invalidResponseMessage)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NeAntikError.proxyTestFailed(invalidResponseMessage)
        }
        guard let dictionary = object as? [String: Any],
              let ipAddress = dictionary["ip"] as? String,
              isIPAddress(ipAddress)
        else {
            throw NeAntikError.proxyTestFailed(
                invalidResponseMessage
            )
        }

        let languages = dictionary["languages"] as? String
        let locale = languages?
            .split(separator: ",")
            .first
            .map {
                String($0).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .flatMap(normalizedLocale)
        let timezone = (dictionary["timezone"] as? String).flatMap {
            TimeZone(identifier: $0) == nil ? nil : $0
        }

        return ProxyTestResult(
            ipAddress: ipAddress,
            city: safeDisplayText(dictionary["city"]),
            countryName: safeDisplayText(dictionary["country_name"]),
            countryCode: safeDisplayText(dictionary["country_code"]) ??
                safeDisplayText(dictionary["country"]),
            timezoneIdentifier: timezone,
            localeIdentifier: locale
        )
    }

    private static func isIPAddress(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 64,
              !value.contains("%"),
              value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return false
        }
        var ipv4 = in_addr()
        if value.withCString({
            inet_pton(AF_INET, $0, &ipv4)
        }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return value.withCString({
            inet_pton(AF_INET6, $0, &ipv6)
        }) == 1
    }

    private static func safeDisplayText(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 128,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return trimmed
    }

    private static func normalizedLocale(_ value: String) -> String? {
        let components = value.replacingOccurrences(
            of: "_",
            with: "-"
        ).split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              (2...3).contains(components[0].count),
              isASCIILetters(components[0])
        else {
            return nil
        }
        if components.count == 2 {
            guard components[1].count == 2,
                  isASCIILetters(components[1])
            else {
                return nil
            }
            return "\(components[0].lowercased())-\(components[1].uppercased())"
        }
        return components[0].lowercased()
    }

    private static func isASCIILetters(_ value: Substring) -> Bool {
        value.utf8.count == value.count &&
            value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
            }
    }

    static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{000B}", with: "\\v")
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var exceeded = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty else { return false }
        let wasExceeded = exceeded
        let remaining = max(0, maximumBytes + 1 - data.count)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if data.count > maximumBytes || chunk.count > remaining {
            exceeded = true
        }
        return exceeded && !wasExceeded
    }

    func snapshot() -> (data: Data, exceeded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, exceeded)
    }
}

private final class ProcessOutputCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<ProxyProcessResult, Error>?
    private var terminationStatus: Int32?
    private var readerSnapshot: (data: Data, exceeded: Bool)?
    private var cancelled = false

    func install(
        _ continuation: CheckedContinuation<ProxyProcessResult, Error>
    ) {
        lock.lock()
        self.continuation = continuation
        let completion = takeCompletionIfReady()
        lock.unlock()
        completion?()
    }

    func processTerminated(status: Int32) {
        lock.lock()
        terminationStatus = status
        let completion = takeCompletionIfReady()
        lock.unlock()
        completion?()
    }

    func readerFinished(_ snapshot: (data: Data, exceeded: Bool)) {
        lock.lock()
        readerSnapshot = snapshot
        let completion = takeCompletionIfReady()
        lock.unlock()
        completion?()
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        let completion = takeCompletionIfReady()
        lock.unlock()
        completion?()
    }

    func fail(_ error: Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func takeCompletionIfReady() -> (() -> Void)? {
        guard let continuation,
              let terminationStatus,
              let readerSnapshot
        else {
            return nil
        }
        self.continuation = nil
        if cancelled {
            return {
                continuation.resume(throwing: CancellationError())
            }
        }
        let result = ProxyProcessResult(
            status: terminationStatus,
            output: readerSnapshot.data,
            outputExceeded: readerSnapshot.exceeded
        )
        return {
            continuation.resume(returning: result)
        }
    }
}

private final class CancellableProcessRunner: @unchecked Sendable {
    let process = Process()

    private let lock = NSLock()
    private var cancelled = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func start() throws {
        lock.lock()
        let shouldStart = !cancelled
        lock.unlock()
        guard shouldStart else {
            throw CancellationError()
        }

        try process.run()

        lock.lock()
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = process.isRunning
        lock.unlock()
        if shouldTerminate {
            process.terminate()
        }
    }

    func stopForOutputLimit() {
        if process.isRunning {
            process.terminate()
        }
    }
}
