import Foundation

struct NeAntikApplicationEnvironment: Equatable, Sendable {
    static let productionBundleIdentifier = "app.neantik.desktop"
    static let developmentBundleIdentifier = "app.neantik.desktop.dev"

    let bundleIdentifier: String
    let applicationSupportDirectoryName: String
    let keychainService: String
    let legacyKeychainService: String?

    var isDevelopment: Bool {
        bundleIdentifier == Self.developmentBundleIdentifier
    }

    static func resolve(
        bundleIdentifier: String?
    ) -> NeAntikApplicationEnvironment {
        if bundleIdentifier == productionBundleIdentifier {
            return NeAntikApplicationEnvironment(
                bundleIdentifier: productionBundleIdentifier,
                applicationSupportDirectoryName: "NeAntik",
                keychainService: KeychainStore.currentService,
                legacyKeychainService: KeychainStore.legacyService
            )
        }
        return NeAntikApplicationEnvironment(
            bundleIdentifier: developmentBundleIdentifier,
            applicationSupportDirectoryName: "NeAntik Development",
            keychainService: "app.neantik.dev.proxy",
            legacyKeychainService: nil
        )
    }

    func applicationSupportRoot(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        developmentFixtureRoot: String? = Bundle.main.object(forInfoDictionaryKey: "NeAntikDevelopmentFixtureRoot") as? String
    ) -> URL {
        // Explicit disposable engineering root; production ignores this hook.
        if isDevelopment, let root = environment["NEANTIK_DEVELOPMENT_DATA_ROOT"] ?? developmentFixtureRoot {
            // standardization can rewrite an EXISTING /private/tmp fixture to
            // the /tmp symlink, which nofollow maintenance must reject. Keep
            // lexical components; only map the known macOS /tmp alias.
            let parts = root.split(separator: "/", omittingEmptySubsequences: false)
            let name: Substring?
            if parts.count == 4, Array(parts.prefix(3)) == ["", "private", "tmp"] { name = parts[3] }
            else if parts.count == 3, Array(parts.prefix(2)) == ["", "tmp"] { name = parts[2] }
            else { name = nil }
            if let name, name.hasPrefix("neantik-"), PersistedInlineText.isSafe(String(name)) {
                return URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(String(name), isDirectory: true)
            }
        }
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        return applicationSupport.appendingPathComponent(
            applicationSupportDirectoryName,
            isDirectory: true
        )
    }
}
