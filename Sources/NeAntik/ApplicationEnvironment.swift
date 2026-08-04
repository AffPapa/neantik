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
        fileManager: FileManager = .default
    ) -> URL {
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
