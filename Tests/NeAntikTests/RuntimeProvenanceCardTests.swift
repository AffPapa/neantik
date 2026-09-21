import Foundation
import Testing
@testable import NeAntik

struct RuntimeProvenanceCardTests {
    @Test
    func cardUsesSafeRuntimeSummaryWithoutPathsOrFullHashes() {
        let runtime = BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: URL(fileURLWithPath: "/private/runtime/Browser"),
            source: "Встроен",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "152.0.7977.64",
                architectures: ["arm64"],
                codeSignatureValid: true,
                executableSHA256: String(repeating: "a", count: 64),
                frameworkSHA256: String(repeating: "b", count: 64)
            )
        )
        let preflight = BrowserRuntimePreflight(errors: [], warnings: [])

        let snapshot = RuntimeProvenanceSnapshot.inspect(
            runtime: runtime,
            preflight: preflight
        )

        #expect(snapshot.name == "NeAntik Browser")
        #expect(snapshot.architecture == "Apple Silicon")
        #expect(snapshot.signature == "Валидна")
        #expect(snapshot.executableDigest == "Измерен локально")
        #expect(snapshot.frameworkDigest == "Измерен локально")
        #expect(snapshot.preflight == "Готов к запуску")
        #expect(!snapshot.source.contains("/private"))
        #expect(!snapshot.executableDigest.contains(String(repeating: "a", count: 64)))
    }

    @Test
    func missingRuntimeIsPresentedAsUnverified() {
        let snapshot = RuntimeProvenanceSnapshot.inspect(
            runtime: nil,
            preflight: nil
        )

        #expect(snapshot.name == "Движок не выбран")
        #expect(snapshot.preflight == "Проверка не завершена")
    }
}
