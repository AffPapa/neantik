import Darwin
import Foundation

/// Shared URL admission for the Chromium manager and the separate WebKit host.
/// Keep this free of SwiftUI and manager process dependencies.
enum BrowserStartURL {
    static func validate(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "about:blank" { return URL(string: trimmed) }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = url.host,
           !host.isEmpty,
           url.user == nil,
           url.password == nil,
           url.port.map({ (1...65_535).contains($0) }) ?? true {
            return url
        }
        let authority = String(trimmed.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        if authority.contains(":") {
            return validatedBareHostPortURL(trimmed, authority: authority)
        }
        if URL(string: trimmed)?.scheme != nil { return nil }
        if let url = URL(string: "https://\(trimmed)"),
           let host = url.host,
           !host.isEmpty,
           url.user == nil,
           url.password == nil {
            return url
        }
        return nil
    }

    private static func validatedBareHostPortURL(_ text: String, authority: String) -> URL? {
        guard !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !authority.contains("@") else { return nil }
        let host: String, portText: String
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[...closing])
            let suffix = authority[authority.index(after: closing)...]
            guard suffix.hasPrefix(":") else { return nil }
            portText = String(suffix.dropFirst())
            var address = in6_addr()
            guard String(host.dropFirst().dropLast()).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            host = String(parts[0]); portText = String(parts[1])
            guard host.lowercased() == "localhost" || host.contains(".") else { return nil }
        }
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(portText), (1...65_535).contains(port),
              ProxyConfiguration(kind: .https, host: host, port: port, username: "").isValid,
              let components = URLComponents(string: "https://\(text)"),
              components.user == nil, components.password == nil,
              components.port == port else { return nil }
        return components.url
    }
}
