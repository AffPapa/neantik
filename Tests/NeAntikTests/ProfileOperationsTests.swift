import Foundation
import Testing
@testable import NeAntik

struct ProfileOperationsTests {
    @Test func healthAllowsLaunchWithProxyWarningButBlocksActiveLock() {
        let profile = BrowserProfile(
            name: "Ads",
            proxy: ProxyConfiguration(kind: .http, host: "proxy.example", port: 8080, username: "")
        )
        let readiness = ProfileReadinessReport.evaluate(
            profile: profile,
            proxyReady: false,
            now: Date(timeIntervalSince1970: 1)
        )
        let warning = ProfileOperationalHealthEvaluator.evaluate(
            profile: profile,
            readiness: readiness,
            now: Date(timeIntervalSince1970: 2)
        )
        #expect(warning.status == ProfileOperationalHealthReport.Status.review)
        #expect(warning.canLaunchWithWarning)
        #expect(warning.primaryIssue?.id == "proxy-check")
        #expect(warning.automaticActionTitles == ["Проверить прокси"])

        let blocked = ProfileOperationalHealthEvaluator.evaluate(
            profile: profile,
            readiness: readiness,
            hasActiveLock: true,
            now: Date(timeIntervalSince1970: 3)
        )
        #expect(blocked.status == ProfileOperationalHealthReport.Status.blocked)
        #expect(!blocked.canLaunchWithWarning)
        #expect(blocked.primaryIssue?.id == "active-lock")
    }

    @Test func cleanupPlanIncludesOnlyKnownDisposableDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Default/Cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Default/Cookies", isDirectory: true),
            withIntermediateDirectories: true
        )

        let plan = ProfileDisposableCleanupPlanner.plan(profileDirectory: root)
        #expect(plan.candidates.map(\.relativePath) == ["Default/Cache"])
    }

    @Test func fixtureFactoryCreatesBoundedLocalCheckerProfiles() {
        let fixtures = CheckerFixtureProfileFactory.makeLocalFixtures(
            now: Date(timeIntervalSince1970: 10)
        )
        #expect(fixtures.count == 4)
        #expect(fixtures.allSatisfy { $0.tags.contains("QA") })
        #expect(fixtures.allSatisfy { $0.proxy == nil })
        #expect(fixtures.map(\.name).contains("QA · Конфликт среды"))
    }

    @Test func releaseQASnapshotSummarizesMissingSiteGate() {
        let snapshot = ReleaseQASnapshotBuilder.build(
            version: "0.6.9",
            build: "51",
            testsPassed: true,
            openSourceTreePassed: true,
            zipNotarized: true,
            dmgNotarized: true,
            githubAssetsVerified: true,
            siteGatePassed: false
        )
        #expect(!snapshot.isReady)
        #expect(snapshot.summary == "Release QA: 5/6 · нужна проверка")
        #expect(snapshot.checks.last?.id == "site")
    }
}
