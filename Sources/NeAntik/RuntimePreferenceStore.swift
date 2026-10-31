import Combine
import Foundation

@MainActor
final class RuntimePreferenceStore: ObservableObject {
    @Published private(set) var preference: BrowserRuntimePreference?
    @Published var lastError: String?

    private let paths: AppPaths

    init(
        paths: AppPaths = AppPaths(),
        defaults: UserDefaults = .standard
    ) {
        self.paths = paths

        do {
            try paths.prepareBaseDirectories()
            try paths.validatePrivateFile(paths.runtimePreferenceFile)
            if FileManager.default.fileExists(
                atPath: paths.runtimePreferenceFile.path
            ) {
                preference = try Self.read(
                    from: paths.runtimePreferenceFile
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: paths.runtimePreferenceFile.path
                )
            } else if let migrated = Self.legacyPreference(
                defaults: defaults
            ) {
                preference = migrated
                try persist()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func select(path: String, flavor: BrowserRuntimeFlavor) throws {
        let previous = preference
        preference = BrowserRuntimePreference(
            path: path,
            flavor: flavor,
            updatedAt: Date()
        )
        do {
            try persist()
        } catch {
            preference = previous
            throw error
        }
    }

    func updateFlavor(_ flavor: BrowserRuntimeFlavor) throws {
        guard var value = preference else { return }
        let previous = preference
        value.flavor = flavor
        value.updatedAt = Date()
        preference = value
        do {
            try persist()
        } catch {
            preference = previous
            throw error
        }
    }

    func clear() throws {
        let previous = preference
        preference = nil
        do {
            if FileManager.default.fileExists(
                atPath: paths.runtimePreferenceFile.path
            ) {
                try FileManager.default.removeItem(
                    at: paths.runtimePreferenceFile
                )
            }
        } catch {
            preference = previous
            throw error
        }
    }

    private func persist() throws {
        guard let preference else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        encoder.dateEncodingStrategy = .iso8601
        try paths.writePrivateFile(
            encoder.encode(preference),
            to: paths.runtimePreferenceFile
        )
    }

    private static func read(from url: URL) throws -> BrowserRuntimePreference {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            BrowserRuntimePreference.self,
            from: Data(contentsOf: url)
        )
    }

    private static func legacyPreference(
        defaults: UserDefaults
    ) -> BrowserRuntimePreference? {
        guard let path = defaults.string(forKey: "customBrowserPath"),
              !path.isEmpty
        else {
            return nil
        }
        let fingerprint = defaults.bool(
            forKey: "customBrowserFingerprintMode"
        )
        return BrowserRuntimePreference(
            path: path,
            flavor: fingerprint ? .fingerprintChromium : .standard,
            updatedAt: Date()
        )
    }
}
