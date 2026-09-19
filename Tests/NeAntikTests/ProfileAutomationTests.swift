import XCTest
@testable import NeAntik

final class ProfileAutomationTests: XCTestCase {
    func testWizardCreatesPurposeTagAndKeepsIsolationDefaults() throws {
        let profile = try ProfileCreationWizard.makeProfile(
            from: ProfileCreationRequest(name: "Студия", purpose: .work),
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(profile.tags, ["работа"])
        XCTAssertNil(profile.proxy)
        XCTAssertEqual(profile.startURL, "about:blank")
    }

    func testIdentityContractReportsOnlyMissingDerivedValues() {
        let profile = BrowserProfile(name: "Test")
        let contract = IdentityContract.derive(from: profile)
        XCTAssertTrue(contract.issues.contains("Часовой пояс не определён"))
        XCTAssertTrue(contract.issues.contains("Размер экрана не определён"))
        XCTAssertFalse(contract.issues.contains("WebRTC не настроен"))
    }

    func testReadinessDoesNotBlockWhenHostDisplayIsNotReportedYet() {
        let profile = BrowserProfile(name: "Test")
        let report = ProfileReadinessReport.evaluate(profile: profile)
        XCTAssertEqual(report.status, .ready)
        XCTAssertFalse(report.issues.contains("Размер экрана не определён"))
        XCTAssertNil(report.primaryIssue)
        XCTAssertNil(report.nextAction)
    }

    func testReadinessExposesOneDeterministicRecoveryAction() {
        let profile = BrowserProfile(name: "Test", proxy: ProxyConfiguration(kind: .http, host: "bad host", port: 0, username: ""))
        let report = ProfileReadinessReport.evaluate(profile: profile, proxyReady: false)
        XCTAssertEqual(report.primaryIssue, "Прокси нужно проверить")
        XCTAssertEqual(report.nextAction, "Проверь подключение прокси в сведениях профиля.")
    }

    func testStabilityDetectsIdentityChange() {
        let first = BrowserProfile(name: "Test", identity: BrowserIdentity(seed: 1))
        let changed = BrowserProfile(name: "Test", identity: BrowserIdentity(seed: 2))
        let previous = ProfileStabilityRecord.capture(profile: first)
        let current = ProfileStabilityRecord.capture(profile: changed, previous: previous)
        XCTAssertTrue(current.fingerprintChanged)
    }

    func testStabilityExplainsProxyCookieAndTabDriftWithoutStoringSecrets() throws {
        let proxy = ProxyConfiguration(kind: .http, host: "127.0.0.1", port: 8080, username: "private")
        let first = BrowserProfile(name: "Test", proxy: proxy)
        let old = ProfileStabilityRecord.capture(profile: first, tabCount: 1, cookieCount: 2)
        let changed = BrowserProfile(name: "Test")
        let current = ProfileStabilityRecord.capture(profile: changed, tabCount: 3, cookieCount: 4, previous: old)
        XCTAssertTrue(current.proxyChanged)
        XCTAssertTrue(current.cookiesChanged)
        XCTAssertTrue(current.tabsChanged)
        let encoded = try JSONEncoder().encode(current)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("private") ?? true)
    }

    func testStabilityStoreIsBoundedAndReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStabilityHistoryStore(rootDirectory: root)
        let profile = BrowserProfile(name: "Test")
        for offset in 0..<25 {
            try store.append(ProfileStabilityRecord.capture(
                profile: profile,
                now: Date(timeIntervalSince1970: TimeInterval(offset))
            ))
        }
        XCTAssertEqual(store.records(for: profile.id).count, 20)
    }

    func testSnapshotCopyIsAtomicAndPreservesContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("BrowserData", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: source.appendingPathComponent("Preferences"))
        let target = try AtomicProfileSnapshotStore(rootDirectory: root).create(
            profileID: UUID(), browserData: source
        )
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Preferences")), Data("ok".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".tmp").path))
    }

    func testChromiumCompatibilityAllowsFirstLaunchAndRecordsMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ChromiumCompatibilityCoordinator(rootDirectory: root)
        let id = UUID()
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "152", profileDataExists: false, snapshotAvailable: false), .firstLaunch)
        try coordinator.record(profileID: id, runtimeVersion: "152", now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "152", profileDataExists: true, snapshotAvailable: true), .compatible)
    }

    func testChromiumCompatibilityRequiresSnapshotForRuntimeMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ChromiumCompatibilityCoordinator(rootDirectory: root)
        let id = UUID()
        try coordinator.record(profileID: id, runtimeVersion: "151")
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "152", profileDataExists: true, snapshotAvailable: false), .rollbackRequired)
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "152", profileDataExists: true, snapshotAvailable: true), .migrate)
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "152", profileDataExists: false, snapshotAvailable: true), .rollbackRequired)
    }

    func testReservedEmptyLaunchRetriesOnlySameRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ChromiumCompatibilityCoordinator(rootDirectory: root)
        let id = UUID()
        try coordinator.record(profileID: id, runtimeVersion: "153", emptyProfileLaunchPending: true)
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "153", profileDataExists: false, snapshotAvailable: false), .firstLaunch)
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "152", profileDataExists: false, snapshotAvailable: true), .rollbackRequired)
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "154", profileDataExists: false, snapshotAvailable: true), .rollbackRequired)
        try coordinator.record(profileID: id, runtimeVersion: "153")
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "153", profileDataExists: false, snapshotAvailable: true), .rollbackRequired)
    }

    func testSnapshotRestoreRejectsAnotherProfileBeforeChangingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("Preferences"))
        let snapshots = AtomicProfileSnapshotStore(rootDirectory: root)
        let owner = UUID()
        let other = UUID()
        try FileManager.default.createDirectory(at: snapshots.root.appendingPathComponent(other.uuidString), withIntermediateDirectories: true)
        let snapshot = try snapshots.create(profileID: owner, browserData: source)
        XCTAssertThrowsError(try snapshots.restore(snapshot: snapshot, to: destination, profileID: other))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Preferences")), Data("keep".utf8))
    }

    func testSnapshotVersionRoundTripAndCorruptMetadataFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let owner = UUID()
        let snapshots = AtomicProfileSnapshotStore(rootDirectory: root)
        let snapshot = try snapshots.create(profileID: owner, browserData: source, runtimeVersion: "152.0.7977.82")
        XCTAssertEqual(try snapshots.restore(snapshot: snapshot, to: destination, profileID: owner), "152.0.7977.82")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("json").path))
        try Data("keep".utf8).write(to: destination.appendingPathComponent("Preferences"))
        try Data("corrupt".utf8).write(to: snapshot.appendingPathExtension("json"))
        XCTAssertThrowsError(try snapshots.restore(snapshot: snapshot, to: destination, profileID: owner))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Preferences")), Data("keep".utf8))
    }

    func testChromiumCompatibilityRequiresKnownRuntimeVersion() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let coordinator = ChromiumCompatibilityCoordinator(rootDirectory: root)
        for version: String? in [nil, "", "unknown", "153..36"] {
            XCTAssertThrowsError(try coordinator.record(profileID: UUID(), runtimeVersion: version))
            XCTAssertFalse(FileManager.default.fileExists(atPath: coordinator.markerURL.path))
            for exists in [true, false] {
                XCTAssertEqual(coordinator.action(for: UUID(), runtimeVersion: version, profileDataExists: exists, snapshotAvailable: true), .rollbackRequired)
            }
        }
    }

    func testChromiumCompatibilityPreservesCorruptAndDuplicateMarkers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = ChromiumCompatibilityCoordinator(rootDirectory: root)
        let id = UUID()
        let marker = ChromiumCompatibilityCoordinator.Marker(profileID: id, runtimeVersion: "153", recordedAt: Date())
        let duplicate = try JSONEncoder.neantikStable.encode([marker, marker])
        for evidence in [Data("invalid-json".utf8), duplicate] {
            try evidence.write(to: coordinator.markerURL)
            XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "153", profileDataExists: true, snapshotAvailable: true), .rollbackRequired)
            XCTAssertThrowsError(try coordinator.record(profileID: id, runtimeVersion: "153"))
            XCTAssertEqual(try Data(contentsOf: coordinator.markerURL), evidence)
        }
    }

    func testChromiumCompatibilityRejectsDowngradeEvenWithSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ChromiumCompatibilityCoordinator(rootDirectory: root)
        let id = UUID()
        try coordinator.record(profileID: id, runtimeVersion: "153.0.8010.36")
        for older in ["152.0.7977.82", "153.0.8010.9"] {
            XCTAssertEqual(coordinator.action(for: id, runtimeVersion: older, profileDataExists: true, snapshotAvailable: true), .rollbackRequired)
        }
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "153.0.8010.100", profileDataExists: true, snapshotAvailable: true), .migrate)
        XCTAssertEqual(coordinator.action(for: id, runtimeVersion: "unknown", profileDataExists: true, snapshotAvailable: true), .rollbackRequired)
    }
}
