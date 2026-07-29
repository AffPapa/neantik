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

struct ProxyTester: Sendable {
    static let curlArguments = [
        "--disable",
        "--silent",
        "--show-error",
        "--fail",
        "--max-time", "12",
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
        standardInput: Data
    ) async throws -> (status: Int32, output: Data) {
        let runner = CancellableProcessRunner(
            executableURL: executableURL,
            arguments: arguments
        )
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
                runner.process.terminationHandler = { process in
                    let outputData =
                        output.fileHandleForReading.readDataToEndOfFile()
                    if runner.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(
                            returning: (
                                status: process.terminationStatus,
                                output: outputData
                            )
                        )
                    }
                }
                do {
                    try runner.start()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            runner.cancel()
        }
    }

    static func parseResponse(_ data: Data) throws -> ProxyTestResult {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let ipAddress = dictionary["ip"] as? String,
              !ipAddress.isEmpty
        else {
            let message = (object as? [String: Any])?["reason"] as? String
            throw NeAntikError.proxyTestFailed(
                message ?? "IP-сервис вернул некорректный ответ."
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
            city: dictionary["city"] as? String,
            countryName: dictionary["country_name"] as? String,
            countryCode: (dictionary["country_code"] as? String) ??
                (dictionary["country"] as? String),
            timezoneIdentifier: timezone,
            localeIdentifier: locale
        )
    }

    private static func normalizedLocale(_ value: String) -> String? {
        let components = value.replacingOccurrences(
            of: "_",
            with: "-"
        ).split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count),
              (2...3).contains(components[0].count),
              components[0].allSatisfy(\.isLetter)
        else {
            return nil
        }
        if components.count == 2 {
            guard components[1].count == 2,
                  components[1].allSatisfy(\.isLetter)
            else {
                return nil
            }
            return "\(components[0].lowercased())-\(components[1].uppercased())"
        }
        return components[0].lowercased()
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
}
