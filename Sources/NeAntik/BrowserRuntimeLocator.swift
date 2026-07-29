import Foundation

struct BrowserRuntimeLocator: Sendable {
    private typealias Candidate = (
        name: String,
        url: URL,
        source: String,
        flavor: BrowserRuntimeFlavor
    )

    func availableRuntimes(
        preference: BrowserRuntimePreference? = nil
    ) -> [BrowserRuntime] {
        var candidates: [Candidate] = []

        if let preference, !preference.path.isEmpty {
            let executable = normalizedExecutable(
                URL(fileURLWithPath: preference.path)
            )
            let flavor = declaredNeAntikFlavor(
                for: executable
            ) ?? preference.flavor
            candidates.append((
                flavor == .fingerprintChromium
                    ? "NeAntik Browser"
                    : flavor.title,
                executable,
                "Выбран вручную",
                flavor
            ))
        }

        candidates.append(contentsOf: cloakRuntimes())

        if let resources = Bundle.main.resourceURL {
            let neAntikApp = resources.appendingPathComponent(
                "NeAntik Browser.app",
                isDirectory: true
            )
            candidates.append((
                "NeAntik Browser",
                normalizedExecutable(neAntikApp),
                "Встроен",
                .fingerprintChromium
            ))
            let chromiumApp = resources.appendingPathComponent(
                "Chromium.app",
                isDirectory: true
            )
            candidates.append((
                "Встроенный Chromium",
                normalizedExecutable(chromiumApp),
                "Встроен",
                .standard
            ))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let installedCandidates: [Candidate] = [
            (
                name: "Chromium",
                url: URL(
                    fileURLWithPath:
                        "/Applications/Chromium.app/Contents/MacOS/Chromium"
                ),
                source: "Программы",
                flavor: .standard
            ),
            (
                name: "Google Chrome",
                url: URL(
                    fileURLWithPath:
                        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                ),
                source: "Программы",
                flavor: .standard
            ),
            (
                name: "Chromium",
                url: home.appendingPathComponent(
                    "Applications/Chromium.app/Contents/MacOS/Chromium"
                ),
                source: "Программы пользователя",
                flavor: .standard
            ),
            (
                name: "Google Chrome",
                url: home.appendingPathComponent(
                    "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                ),
                source: "Программы пользователя",
                flavor: .standard
            )
        ]
        candidates.append(contentsOf: installedCandidates)

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let path = candidate.url.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  FileManager.default.isExecutableFile(atPath: path)
            else {
                return nil
            }
            let inspection = BrowserRuntimeInspector.inspect(
                executableURL: candidate.url
            )
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
    }

    func preferredRuntime(
        preference: BrowserRuntimePreference? = nil
    ) -> BrowserRuntime? {
        if let preference, !preference.path.isEmpty {
            let executable = normalizedExecutable(
                URL(fileURLWithPath: preference.path)
            )
            if FileManager.default.isExecutableFile(
                atPath: executable.path
            ) {
                let inspection = BrowserRuntimeInspector.inspect(
                    executableURL: executable
                )
                if inspection.supportsAppleSilicon {
                    let flavor = declaredNeAntikFlavor(
                        for: executable
                    ) ?? preference.flavor
                    return BrowserRuntime(
                        name: flavor == .fingerprintChromium
                            ? "NeAntik Browser"
                            : flavor.title,
                        executableURL: executable,
                        source: "Выбран вручную",
                        flavor: flavor,
                        inspection: inspection
                    )
                }
            }
        }
        return availableRuntimes(preference: preference).first
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
                (
                    "Cloak Chromium",
                    $0.appendingPathComponent(
                        "Chromium.app/Contents/MacOS/Chromium"
                    ),
                    "External · Cloak",
                    .cloak
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
