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
}
