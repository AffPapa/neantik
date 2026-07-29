import Darwin
import Foundation

struct ProxyTestResult: Sendable {
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

struct ProxyProcessResult: Sendable {
    let status: Int32
    let output: Data
    let outputExceeded: Bool
}

struct ProxyTester: Sendable {
    static let maximumResponseBytes = 16_384
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
        "https://ipapi.co/json/"
    ]

    func test(
        configuration: ProxyConfiguration,
        password: String
    ) async throws -> ProxyTestResult {
        guard configuration.isValid else {
            throw NeAntikError.invalidProxy
        }
        guard password.count <= 4_096, !password.contains("\0") else {
            throw NeAntikError.invalidProxy
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
        let result = try await Self.runCancellableProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: Self.curlArguments,
            standardInput: inputData
        )
        guard !result.outputExceeded else {
            throw NeAntikError.proxyTestFailed(
                Self.invalidResponseMessage
            )
        }
        guard result.status == 0 else {
            throw NeAntikError.proxyTestFailed(
                result.status == 28
                    ? "Сервер не ответил за 12 секунд. Проверь адрес, порт и доступность прокси."
                    : "Не удалось подключиться. Проверь адрес, порт, тип прокси и данные для входа."
            )
        }

        return try Self.parseResponse(result.output)
    }

    static func runCancellableProcess(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        maximumOutputBytes: Int = maximumResponseBytes
    ) async throws -> ProxyProcessResult {
        let runner = CancellableProcessRunner(
            executableURL: executableURL,
            arguments: arguments
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

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
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
