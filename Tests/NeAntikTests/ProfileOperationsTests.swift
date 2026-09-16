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

    @Test func healthExplainsStaleAndIncompleteProxyReceipts() {
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        let profile = BrowserProfile(
            name: "Ads",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "proxy.example",
                port: 8080,
                username: ""
            )
        )
        let readiness = ProfileReadinessReport.evaluate(
            profile: profile,
            proxyReady: true,
            now: now
        )
        let staleHealth = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: now.addingTimeInterval(
                    -ProxyHealthState.freshnessLifetime - 1
                ),
                outcome: .succeeded
            ),
            lastSuccess: ProxyHealthSuccess(
                observedAt: now.addingTimeInterval(
                    -ProxyHealthState.freshnessLifetime - 1
                ),
                responseTimeMilliseconds: 100,
                exitAddressWasObserved: true,
                city: nil,
                countryName: "Germany",
                countryCode: "DE",
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE"
            )
        )
        let incompleteHealth = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: now.addingTimeInterval(-60),
                outcome: .succeeded
            ),
            lastSuccess: nil
        )

        let stale = ProfileOperationalHealthEvaluator.evaluate(
            profile: profile,
            readiness: readiness,
            proxyHealth: staleHealth,
            now: now
        )
        let incomplete = ProfileOperationalHealthEvaluator.evaluate(
            profile: profile,
            readiness: readiness,
            proxyHealth: incompleteHealth,
            now: now
        )

        #expect(stale.primaryIssue?.id == "proxy-stale")
        #expect(stale.automaticActionTitles == ["Проверить прокси"])
        #expect(incomplete.primaryIssue?.id == "proxy-context")
    }



    @Test func proxyFreshnessMarksRecentChecksFreshAndOldChecksStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(checkedAt: now.addingTimeInterval(-60), outcome: .succeeded),
            lastSuccess: nil
        )
        let stale = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: now.addingTimeInterval(-ProxyHealthState.freshnessLifetime - 1),
                outcome: .succeeded
            ),
            lastSuccess: nil
        )
        #expect(fresh.isFresh(relativeTo: now))
        #expect(!stale.isFresh(relativeTo: now))
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



    @Test func cleanupExecutorDeletesOnlyDisposableDirectoriesAndSkipsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Default/Cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Default", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Default/GPUCache"),
            withDestinationURL: outside
        )

        let plan = ProfileDisposableCleanupPlanner.plan(profileDirectory: root)
        let result = ProfileDisposableCleanupExecutor.execute(plan: plan, profileDirectory: root)

        #expect(result.removedRelativePaths == ["Default/Cache"])
        #expect(result.skipped == [.init(relativePath: "Default/GPUCache", reason: "Symlink не удаляется")])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Default/Cache").path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
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
            version: "0.6.10",
            build: "52",
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
