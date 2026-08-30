import Foundation

struct BrowserRuntimeLocator: Sendable {
    private let runtimeInspector:
        @Sendable (URL) -> BrowserRuntimeInspection
    private let candidateOverrides: [Candidate]?
    private let allowsExternalRuntimes: Bool
    private let resourceURL: URL?

    struct Candidate: Sendable {
        let name: String
        let url: URL
        let source: String
        let flavor: BrowserRuntimeFlavor
    }

    init(
        runtimeInspector: @escaping @Sendable
            (URL) -> BrowserRuntimeInspection = {
                BrowserRuntimeInspector.inspectForStartup(
                    executableURL: $0
                )
            },
        allowsExternalRuntimes: Bool = false,
        resourceURL: URL? = Bundle.main.resourceURL
    ) {
        self.runtimeInspector = runtimeInspector
        self.candidateOverrides = nil
        self.allowsExternalRuntimes = allowsExternalRuntimes
        self.resourceURL = resourceURL
    }

    init(
        runtimeInspector: @escaping @Sendable
            (URL) -> BrowserRuntimeInspection,
        candidates: [Candidate]
    ) {
        self.runtimeInspector = runtimeInspector
        self.candidateOverrides = candidates
        self.allowsExternalRuntimes = false
        self.resourceURL = nil
    }

    func preferredRuntime(
        preference: BrowserRuntimePreference? = nil
    ) -> BrowserRuntime? {
        var seen = Set<String>()
        for candidate in runtimeCandidates(preference: preference) {
            if let runtime = resolve(candidate: candidate, seen: &seen) {
                return runtime
            }
        }
        return nil
    }

    private func runtimeCandidates(
        preference: BrowserRuntimePreference?
    ) -> [Candidate] {
        if let candidateOverrides {
            return candidateOverrides
        }
        var candidates: [Candidate] = []

        if allowsExternalRuntimes,
           let preference,
           !preference.path.isEmpty {
            let executable = normalizedExecutable(
                URL(fileURLWithPath: preference.path)
            )
            let flavor = declaredNeAntikFlavor(
                for: executable
            ) ?? preference.flavor
            candidates.append(Candidate(
                name: flavor == .fingerprintChromium
                    ? "NeAntik Browser"
                    : flavor.title,
                url: executable,
                source: "Выбран вручную",
                flavor: flavor
            ))
        }

        if let resources = resourceURL {
            let neAntikApp = resources.appendingPathComponent(
                "NeAntik Browser.app",
                isDirectory: true
            )
            let executable = normalizedExecutable(neAntikApp)
            if declaredNeAntikFlavor(for: executable) ==
                .fingerprintChromium {
                candidates.append(Candidate(
                    name: "NeAntik Browser",
                    url: executable,
                    source: "Встроен",
                    flavor: .fingerprintChromium
                ))
            }
        }

        guard allowsExternalRuntimes else {
            return candidates
        }

        candidates.append(contentsOf: cloakRuntimes())

        let home = FileManager.default.homeDirectoryForCurrentUser
        let installedCandidates: [Candidate] = [
            Candidate(
                name: "Chromium",
                url: URL(
                    fileURLWithPath:
                        "/Applications/Chromium.app/Contents/MacOS/Chromium"
                ),
                source: "Программы",
                flavor: .standard
            ),
            Candidate(
                name: "Google Chrome",
                url: URL(
                    fileURLWithPath:
                        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                ),
                source: "Программы",
                flavor: .standard
            ),
            Candidate(
                name: "Chromium",
                url: home.appendingPathComponent(
                    "Applications/Chromium.app/Contents/MacOS/Chromium"
                ),
                source: "Программы пользователя",
                flavor: .standard
            ),
            Candidate(
                name: "Google Chrome",
                url: home.appendingPathComponent(
                    "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                ),
                source: "Программы пользователя",
                flavor: .standard
            )
        ]
        candidates.append(contentsOf: installedCandidates)

        return candidates
    }

    private func resolve(
        candidate: Candidate,
        seen: inout Set<String>
    ) -> BrowserRuntime? {
        let path = candidate.url.standardizedFileURL.path
        guard seen.insert(path).inserted,
              FileManager.default.isExecutableFile(atPath: path)
        else {
            return nil
        }
        let inspection = runtimeInspector(candidate.url)
        guard inspection.supportsAppleSilicon else {
            return nil
        }
        return BrowserRuntime(
            name: candidate.name,
            executableURL: candidate.url,
            source: candidate.source,
            flavor: candidate.flavor,
            inspection: inspection
        )
    }

    private func cloakRuntimes() -> [Candidate] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloakbrowser", isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories
            .filter { $0.lastPathComponent.hasPrefix("chromium-") }
            .sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: .numeric
                ) == .orderedDescending
            }
            .map {
                Candidate(
                    name: "Cloak Chromium",
                    url: $0.appendingPathComponent(
                        "Chromium.app/Contents/MacOS/Chromium"
                    ),
                    source: "External · Cloak",
                    flavor: .cloak
                )
            }
    }

    func recommendedFlavor(for url: URL) -> BrowserRuntimeFlavor {
        let executable = normalizedExecutable(url)
        if let declared = declaredNeAntikFlavor(for: executable) {
            return declared
        }
        let path = executable.standardizedFileURL.path.lowercased()
        if path.contains("/.cloakbrowser/") ||
            path.contains("cloakbrowser") {
            return .cloak
        }
        if path.contains("fingerprint-chromium") ||
            path.contains("fingerprint chromium") ||
            path.contains("fingerprint_chromium") {
            return .fingerprintChromium
        }
        return .standard
    }

    private func declaredNeAntikFlavor(
        for executableURL: URL
    ) -> BrowserRuntimeFlavor? {
        guard let appURL = appBundleURL(for: executableURL) else {
            return nil
        }
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ),
              let dictionary = object as? [String: Any],
              dictionary["CFBundleIdentifier"] as? String ==
                "app.neantik.runtime",
              dictionary["NeAntikRuntimeFlavor"] as? String ==
                "fingerprint-chromium"
        else {
            return nil
        }
        return .fingerprintChromium
    }

    private func appBundleURL(for url: URL) -> URL? {
        var candidate = url
        for _ in 0..<6 {
            if candidate.pathExtension.lowercased() == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    func normalizedExecutable(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() == "app" else { return url }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: infoURL),
           let object = try? PropertyListSerialization.propertyList(
               from: data,
               format: nil
           ),
           let dictionary = object as? [String: Any],
           let executable = dictionary["CFBundleExecutable"] as? String,
           !executable.isEmpty,
           executable != ".",
           executable != "..",
           !executable.contains("/") {
            return url.appendingPathComponent(
                "Contents/MacOS/\(executable)"
            )
        }
        let fallback = url.deletingPathExtension().lastPathComponent
        return url.appendingPathComponent("Contents/MacOS/\(fallback)")
    }
}
