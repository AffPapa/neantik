import Foundation

/// Credential-free input for detecting an endpoint assigned to more than one
/// local profile. The comparison deliberately excludes usernames, passwords,
/// observed network data and every browser-identity field.
struct ProxyReuseInput: Equatable, Sendable {
    let profileID: UUID
    let kind: ProxyKind?
    let host: String?
    let port: Int?

    init(
        profileID: UUID,
        kind: ProxyKind?,
        host: String?,
        port: Int?
    ) {
        self.profileID = profileID
        self.kind = kind
        self.host = host
        self.port = port
    }

    init(profileID: UUID, proxy: ProxyConfiguration?) {
        self.init(
            profileID: profileID,
            kind: proxy?.kind,
            host: proxy?.host,
            port: proxy?.port
        )
    }

    static func direct(profileID: UUID) -> ProxyReuseInput {
        ProxyReuseInput(
            profileID: profileID,
            kind: nil,
            host: nil,
            port: nil
        )
    }

    static func profiles(
        _ profiles: [BrowserProfile],
        excluding profileID: UUID?
    ) -> [ProxyReuseInput] {
        profiles.compactMap { profile in
            guard profile.id != profileID else { return nil }
            return ProxyReuseInput(profileID: profile.id, proxy: profile.proxy)
        }
    }
}

/// Pure, local-only assessment of whether a proxy route is reused.
///
/// Host normalization never resolves DNS or opens a network connection. It
/// only trims the model boundary, folds DNS/IPv6 letter case and unwraps the
/// conventional brackets around an IPv6 literal.
struct ProxyReuseAssessment: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case direct
        case dedicated
        case shared
    }

    let status: Status
    let otherProfileCount: Int

    var shouldWarn: Bool {
        status == .shared
    }

    var warningText: String? {
        guard shouldWarn else { return nil }
        let suffix = otherProfileCount == 1 ? "профилю" : "профилям"
        return "Этот прокси назначен ещё \(otherProfileCount) \(suffix). " +
            "Проверьте, должно ли подключение быть общим."
    }

    static func assess(
        selectedProfileID: UUID,
        profiles: [BrowserProfile]
    ) -> ProxyReuseAssessment {
        assess(
            selectedProfileID: selectedProfileID,
            among: profiles.map {
                ProxyReuseInput(profileID: $0.id, proxy: $0.proxy)
            }
        )
    }

    static func assess(
        selectedProfileID: UUID,
        among inputs: [ProxyReuseInput]
    ) -> ProxyReuseAssessment {
        guard let selected = inputs.first(where: {
            $0.profileID == selectedProfileID
        }), let selectedRoute = NormalizedRoute(selected)
        else {
            return ProxyReuseAssessment(
                status: .direct,
                otherProfileCount: 0
            )
        }

        let otherProfileCount = inputs.reduce(into: 0) { count, input in
            guard input.profileID != selectedProfileID,
                  NormalizedRoute(input) == selectedRoute
            else {
                return
            }
            count += 1
        }
        return ProxyReuseAssessment(
            status: otherProfileCount == 0 ? .dedicated : .shared,
            otherProfileCount: otherProfileCount
        )
    }

    private struct NormalizedRoute: Equatable, Sendable {
        let kind: ProxyKind
        let host: String
        let port: Int

        init?(_ input: ProxyReuseInput) {
            guard let kind = input.kind,
                  let rawHost = input.host,
                  let port = input.port,
                  (1...65_535).contains(port)
            else {
                return nil
            }

            var host = rawHost.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if host.hasPrefix("["), host.hasSuffix("]") {
                host.removeFirst()
                host.removeLast()
            }
            guard !host.isEmpty else { return nil }

            self.kind = kind
            self.host = host.lowercased(
                with: Locale(identifier: "en_US_POSIX")
            )
            self.port = port
        }
    }
}
