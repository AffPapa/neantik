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

        return try await Task.detached(priority: .userInitiated) {
            try Self.runCurl(configuration: configuration, password: password)
        }.value
    }

    private static func runCurl(
        configuration: ProxyConfiguration,
        password: String
    ) throws -> ProxyTestResult {
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = curlArguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var config = "proxy = \"\(escaped(configuration.curlServer))\"\n"
        if !configuration.username.isEmpty {
            let credentials = "\(configuration.username):\(password)"
            config += "proxy-user = \"\(escaped(credentials))\"\n"
        }

        try process.run()
        input.fileHandleForWriting.write(Data(config.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NeAntikError.proxyTestFailed(
                process.terminationStatus == 28
                    ? "Сервер не ответил за 12 секунд. Проверь адрес, порт и доступность прокси."
                    : "Не удалось подключиться. Проверь адрес, порт, тип прокси и данные для входа."
            )
        }

        return try parseResponse(outputData)
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
