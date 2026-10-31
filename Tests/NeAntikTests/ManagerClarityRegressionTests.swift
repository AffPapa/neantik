import Foundation
import Testing
@testable import NeAntik

struct ManagerClarityRegressionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [0.0, 900.0, 901.0, -301.0])
    func environmentAndSummaryAgreeAboutPreflightAge(age: Double) throws {
        let profile = BrowserProfile(name: "Synthetic", proxy: ProxyConfiguration(
            kind: .http, host: "proxy.example", port: 8080, username: ""))
        let observed = now.addingTimeInterval(-age)
        let health = ProxyHealthUpdatePolicy.success(ProxyTestObservation(
            observedAt: observed, responseTimeMilliseconds: 10,
            result: ProxyTestResult(ipAddress: "203.0.113.1", city: "Fixture",
                countryName: "Fixture", countryCode: "US", timezoneIdentifier: "America/New_York", localeIdentifier: "en-US")))
        let snapshot = ProfileEnvironmentInspector.snapshot(profile: profile, runtime: nil,
            proxyHealth: health, now: now)
        let fields = snapshot.sections.flatMap(\.fields)
        let current = age >= -ProxyCheckSummary.toleratedFutureSkew && age <= ProxyCheckSummary.freshnessLifetime
        #expect(try #require(fields.first { $0.id == "route.last-probe" }).severity == (current ? .success : .attention))
        #expect(try #require(fields.first { $0.id == "geolocation.location" }).severity == (current ? .success : .attention))
    }

    @Test func failedAttemptDoesNotMakePreviousGeoIPCurrent() throws {
        let profile = BrowserProfile(name: "Synthetic", proxy: ProxyConfiguration(kind: .http, host: "proxy.example", port: 8080, username: ""))
        let success = ProxyHealthSuccess(observedAt: now.addingTimeInterval(-30), responseTimeMilliseconds: 10,
            exitAddressWasObserved: true, city: "Fixture", countryName: "Fixture", countryCode: "US",
            timezoneIdentifier: "America/New_York", localeIdentifier: "en-US")
        let health = ProxyHealthState(latestAttempt: ProxyHealthAttempt(checkedAt: now, outcome: .timedOut), lastSuccess: success)
        let fields = ProfileEnvironmentInspector.snapshot(profile: profile, runtime: nil, proxyHealth: health, now: now).sections.flatMap(\.fields)
        #expect(try #require(fields.first { $0.id == "geolocation.location" }).severity == .attention)
        #expect(try #require(fields.first { $0.id == "route.last-probe" }).severity == .failure)
    }

    @Test(arguments: [DiagnosticEvidenceState.configured, .derived, .observed, .unavailable, .unverified])
    func successfulBadgeRespectsEvidenceSource(state: DiagnosticEvidenceState) {
        let field = EnvironmentDiagnosticField(id: "fixture", title: "Fixture", value: "Fixture", state: state, severity: .success)
        #expect(EnvironmentFieldPresentation.title(for: field) == (state == .observed ? "Подтверждено" : state.title))
        let failure = EnvironmentDiagnosticField(id: "fixture", title: "Fixture", value: "Fixture", state: state, severity: .failure)
        #expect(EnvironmentFieldPresentation.title(for: failure) == DiagnosticSeverityPresentation.title(for: .failure))
    }

    @Test func commandNamesDescribeManagerSelection() {
        #expect(ProfileCommandPresentation.openTitle(for: .stopped) == "Запустить профиль")
        #expect(ProfileCommandPresentation.openTitle(for: .checking) == "Показать в менеджере")
    }

    @Test func proxyFailureDescriptionsDoNotClaimAnUnobservedCause() {
        #expect(ProxyTester.outcome(forCurlStatus: 5) == .nameResolutionFailed)
        #expect(ProxyTester.outcome(forCurlStatus: 6) == .nameResolutionFailed)
        #expect(ProxyTester.outcome(forCurlStatus: 28) == .timedOut)
        #expect(ProxyHealthOutcome.nameResolutionFailed.userSummary.contains("или сервиса"))
        #expect(!ProxyHealthOutcome.timedOut.userSummary.contains("12 секунд"))
    }

    private func canonicalMetadata(_ profile: BrowserProfile) throws -> Data {
        // Disk metadata uses second-resolution ISO8601 dates; compare that actual contract.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(profile)
    }

    @MainActor @Test func additiveSnapshotImportPreservesExistingBrowserData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-clarity-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        let store = ProfileStore(paths: paths)
        let original = try store.upsert(BrowserProfile(name: "Synthetic existing"))
        let data = paths.browserDataDirectory(for: original.id)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let marker = data.appendingPathComponent("owned-data-marker")
        try Data("synthetic protected data".utf8).write(to: marker)
        let saved = try ProfileSnapshotStore.save(profiles: [original], folderNameByProfileID: [:], paths: paths)
        let copies = try ProfileSnapshotStore.restore(from: saved, paths: paths)
        let imported = try await store.insertImportedProfilesOffMainActor(copies, folderNames: [nil])
        #expect(try canonicalMetadata(try #require(store.profile(withID: original.id))) == canonicalMetadata(original))
        #expect(store.profiles.count == 2)
        #expect(imported[0].id != original.id)
        #expect(imported[0].identity.runtimeSeed != original.identity.runtimeSeed)
        #expect(try Data(contentsOf: marker) == Data("synthetic protected data".utf8))
        #expect(!FileManager.default.fileExists(atPath: paths.browserDataDirectory(for: imported[0].id).appendingPathComponent("owned-data-marker").path))
    }

    @Test func cancelledProbeDoesNotSendFallbackOrReplaceCancellation() async throws {
        let calls = ProbeCallLedger()
        let task = Task {
            try await ProxyTester().probe(configuration: ProxyConfiguration(kind: .http, host: "proxy.example", port: 8080, username: ""), password: "", runProcess: { _, _, _, _ in
                await calls.record()
                withUnsafeCurrentTask { $0?.cancel() }
                return ProxyProcessResult(status: 6, output: Data(), outputExceeded: false)
            })
        }
        do { _ = try await task.value; Issue.record("Cancelled probe returned an observation") }
        catch is CancellationError { }
        catch { Issue.record("Cancelled probe replaced cancellation with another outcome") }
        #expect(await calls.count == 1)
    }
}

private actor ProbeCallLedger {
    private(set) var count = 0
    func record() { count += 1 }
}
