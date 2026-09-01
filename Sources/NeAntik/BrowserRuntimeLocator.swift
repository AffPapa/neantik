import Foundation

struct BrowserRuntimeLocator: Sendable {
    private let runtimeInspector:
        @Sendable (URL) -> BrowserRuntimeInspection
    private let candidateOverrides: [Candidate]?
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
        resourceURL: URL? = Bundle.main.resourceURL
    ) {
        self.runtimeInspector = runtimeInspector
        self.candidateOverrides = nil
        self.resourceURL = resourceURL
    }

    init(
        runtimeInspector: @escaping @Sendable
            (URL) -> BrowserRuntimeInspection,
        candidates: [Candidate]
    ) {
        self.runtimeInspector = runtimeInspector
        self.candidateOverrides = candidates
        self.resourceURL = nil
    }

    func preferredRuntime() -> BrowserRuntime? {
        var seen = Set<String>()
        for candidate in runtimeCandidates() {
            if let runtime = resolve(candidate: candidate, seen: &seen) {
                return runtime
            }
        }
        return nil
    }

    private func runtimeCandidates() -> [Candidate] {
        if let candidateOverrides {
            return candidateOverrides
        }
        guard let resources = resourceURL else { return [] }
        let neAntikApp = resources.appendingPathComponent(
            "NeAntik Browser.app",
            isDirectory: true
        )
        let executable = normalizedExecutable(neAntikApp)
        guard declaredNeAntikFlavor(for: executable) ==
            .fingerprintChromium
        else {
            return []
        }
        return [Candidate(
            name: "NeAntik Browser",
            url: executable,
            source: "Встроен",
            flavor: .fingerprintChromium
        )]
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
