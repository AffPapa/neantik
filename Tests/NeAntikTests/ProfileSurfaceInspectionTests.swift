import Foundation
import Testing
@testable import NeAntik

struct ProfileSurfaceInspectionTests {
    @Test func scansExtensionManifestWithoutReturningManifestContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let version = root.appendingPathComponent("Extensions/abc/1.2.3", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        let manifest = """
        {"name":"Review helper","version":"1.2.3","permissions":["storage","webRequest"],"host_permissions":["https://example.test/*"]}
        """
        try Data(manifest.utf8).write(to: version.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let report = ExtensionSurfaceScanner.scan(profileDirectory: root)
        #expect(report.isAvailable)
        #expect(report.extensions.count == 1)
        let item = try #require(report.extensions.first)
        #expect(item.name == "Review helper")
        #expect(item.permissionCount == 2)
        #expect(item.hostAccessCount == 1)
        #expect(item.risk == .review)
    }

    @Test func missingExtensionDirectoryMeansNoInstalledExtensions() {
        let report = ExtensionSurfaceScanner.scan(profileDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(report.isAvailable)
        #expect(report.extensions.isEmpty)
    }

    @Test func broadHostAccessIsMarkedForReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let version = root.appendingPathComponent("Extensions/abc/1", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data(#"{"name":"Broad","host_permissions":["<all_urls>"]}"#.utf8).write(to: version.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ExtensionSurfaceScanner.scan(profileDirectory: root).requiresReview)
    }

    @Test func memoryPolicyKeepsFocusedAndSuspendsOldInactiveProcessUnderPressure() {
        let focused = UUID()
        let old = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshots = [
            MemoryProcessSnapshot(profileID: focused, processID: 1, residentBytes: 900, lastActivity: now, isFocused: true),
            MemoryProcessSnapshot(profileID: old, processID: 2, residentBytes: 900, lastActivity: now.addingTimeInterval(-3_600), isFocused: false)
        ]
        let decisions = AutomaticMemorySavingPolicy.decide(snapshots, now: now, residentThreshold: 1_000, inactiveInterval: 60)
        #expect(decisions.first?.action == .keepRunning)
        #expect(decisions.last?.action == .suspend)
    }

    @Test func memoryPolicyDoesNotSuspendRecentlyUsedProcess() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let decision = AutomaticMemorySavingPolicy.decide([
            MemoryProcessSnapshot(profileID: id, processID: 1, residentBytes: 2_000, lastActivity: now.addingTimeInterval(-10), isFocused: false)
        ], now: now, residentThreshold: 1_000, inactiveInterval: 60).first
        #expect(decision?.action == .keepRunning)
    }
}
