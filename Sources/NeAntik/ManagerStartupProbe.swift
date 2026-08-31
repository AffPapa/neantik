import Darwin
import Foundation

struct ManagerStartupIsolationConfiguration: Equatable, Sendable {
    let readyURL: URL
    let dataRoot: URL
    let keychainService: String
}

private enum ManagerStartupProbeError: Error {
    case keychainAccessDisabled
}

/// Startup measurements must never inspect or mutate a developer's normal
/// NeAntik data or Keychain. This backend makes reads empty and fails closed
/// if the isolated empty workspace ever tries to mutate a credential.
struct ManagerStartupKeychainBackend: KeychainBackend {
    func data(service: String, profileID: UUID) throws -> Data? {
        nil
    }

    func upsert(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        throw ManagerStartupProbeError.keychainAccessDisabled
    }

    func delete(service: String, profileID: UUID) throws {
        throw ManagerStartupProbeError.keychainAccessDisabled
    }
}

enum ManagerStartupProbe {
    static let readyEnvironmentKey = "NEANTIK_STARTUP_READY_PATH"
    static let dataRootEnvironmentKey = "NEANTIK_STARTUP_DATA_ROOT"
    static let keychainServiceEnvironmentKey =
        "NEANTIK_STARTUP_KEYCHAIN_SERVICE"

    private static let lock = NSLock()
    private static var didSignal = false

    static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[readyEnvironmentKey] != nil
    }

    static func isolationConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> ManagerStartupIsolationConfiguration? {
        guard bundleIdentifier ==
                NeAntikApplicationEnvironment.developmentBundleIdentifier,
              let rawReadyPath = environment[readyEnvironmentKey],
              let readyURL = validatedOutputURL(rawReadyPath),
              let rawDataRoot = environment[dataRootEnvironmentKey],
              let dataRoot = validatedDataRoot(rawDataRoot),
              let keychainService =
                environment[keychainServiceEnvironmentKey],
              validatedKeychainService(keychainService),
              canonicalParent(of: readyURL) ==
                canonicalParent(of: dataRoot)
        else { return nil }
        return ManagerStartupIsolationConfiguration(
            readyURL: readyURL,
            dataRoot: dataRoot,
            keychainService: keychainService
        )
    }

    static func signalReadyIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        guard let configuration = isolationConfiguration(
            environment: environment,
            bundleIdentifier: bundleIdentifier
        )
        else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !didSignal else { return }
        do {
            let payload = try JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 1,
                    "state": "ready",
                ],
                options: [.sortedKeys]
            )
            try payload.write(to: configuration.readyURL, options: .atomic)
            didSignal = true
        } catch {
            // A developer-only measurement probe must never alter app state or
            // turn a successful manager launch into a user-visible failure.
        }
    }

    static func validatedOutputURL(_ rawPath: String) -> URL? {
        guard isCanonicalStartupPath(rawPath) else {
            return nil
        }
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard url.isFileURL,
              isCanonicalStartupPath(url.path),
              url.pathExtension == "json"
        else { return nil }
        return url
    }

    static func validatedDataRoot(_ rawPath: String) -> URL? {
        guard isCanonicalStartupPath(rawPath) else {
            return nil
        }
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard url.isFileURL,
              isCanonicalStartupPath(url.path),
              url.lastPathComponent.hasPrefix("data-"),
              url.pathExtension.isEmpty,
              isPrivateOwnedDirectory(url)
        else { return nil }
        return url
    }

    private static func isCanonicalStartupPath(_ path: String) -> Bool {
        path.hasPrefix("/private/tmp/neantik-startup-") ||
            path.hasPrefix("/tmp/neantik-startup-")
    }

    private static func canonicalParent(of url: URL) -> URL {
        url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static func validatedKeychainService(_ service: String) -> Bool {
        let prefix = "app.neantik.dev.startup."
        guard service.hasPrefix(prefix), service.count <= 120 else {
            return false
        }
        return service.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }
    }

    private static func isPrivateOwnedDirectory(_ url: URL) -> Bool {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              (status.st_mode & 0o077) == 0
        else { return false }
        return true
    }
}
