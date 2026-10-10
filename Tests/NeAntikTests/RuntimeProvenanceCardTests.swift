import Foundation
import Testing
@testable import NeAntik

struct RuntimeProvenanceCardTests {
    @Test
    func managerWarningMatchesCheckedReleaseBaseline() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let baselineFile = repository.appendingPathComponent(
            "runtime/security-baseline.json"
        )
        let data = try Data(contentsOf: baselineFile)
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let releaseMinimum = try #require(
            document["minimumPublicChromiumVersion"] as? String
        )

        #expect(
            NeAntikRuntimeSecurityBaseline.minimumPublicChromiumVersionText
                == releaseMinimum
        )
    }

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
        #expect(
            snapshot.publicReleaseStatus.contains(
                "Ниже baseline 155.0.8059.40"
            )
        )
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
        #expect(snapshot.publicReleaseStatus == "Не определён")
    }

    @Test
    func cardMarksSecurityBaselineAsSatisfiedForCurrentChromium() {
        let runtime = BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: URL(fileURLWithPath: "/private/runtime/Browser"),
            source: "Встроен",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "155.0.8059.40",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )

        let snapshot = RuntimeProvenanceSnapshot.inspect(
            runtime: runtime,
            preflight: BrowserRuntimePreflight(errors: [], warnings: [])
        )

        #expect(snapshot.publicReleaseStatus == "Соответствует baseline")
    }

    @Test
    func bundledChromiumBelowCurrentReleaseGateIsFlagged() {
        let runtime = BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: URL(fileURLWithPath: "/private/runtime/Browser"),
            source: "Встроен",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "154.0.8037.93",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )

        let snapshot = RuntimeProvenanceSnapshot.inspect(
            runtime: runtime,
            preflight: BrowserRuntimePreflight(errors: [], warnings: [])
        )

        #expect(snapshot.publicReleaseStatus.contains("155.0.8059.40"))
        #expect(snapshot.publicReleaseStatus.contains("заблокирован"))
    }
}
