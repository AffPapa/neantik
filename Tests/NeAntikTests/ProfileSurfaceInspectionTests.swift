import Foundation
import Testing
@testable import NeAntik

struct ProfileSurfaceInspectionTests {
    @Test func scansExtensionManifestWithoutReturningManifestContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let version = root.appendingPathComponent(
            "Default/Extensions/abc/1.2.3",
            isDirectory: true
        )
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
        let version = root.appendingPathComponent(
            "Default/Extensions/abc/1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data(#"{"name":"Broad","host_permissions":["<all_urls>"]}"#.utf8).write(to: version.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ExtensionSurfaceScanner.scan(profileDirectory: root).requiresReview)
    }

    @Test func extensionScanUsesNewestVersionManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = root.appendingPathComponent("Default/Extensions/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("1"), withIntermediateDirectories: true)
        try Data(#"{"name":"Old","version":"1"}"#.utf8).write(to: base.appendingPathComponent("1/manifest.json"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("2"), withIntermediateDirectories: true)
        try Data(#"{"name":"Newest","version":"2"}"#.utf8).write(to: base.appendingPathComponent("2/manifest.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let report = ExtensionSurfaceScanner.scan(profileDirectory: root)
        #expect(report.extensions.first?.name == "Newest")
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

    @Test func storageSurfaceCountsNamespacesWithoutReadingState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let localStorage = root.appendingPathComponent(
            "Default/Local Storage/leveldb",
            isDirectory: true
        )
        let indexedDB = root.appendingPathComponent(
            "Default/IndexedDB/https_example.test_0.indexeddb.leveldb",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localStorage,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: indexedDB,
            withIntermediateDirectories: true
        )
        try Data("secret-url-should-never-be-returned".utf8).write(
            to: localStorage.appendingPathComponent("000003.log")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let report = ProfileStorageSurfaceScanner.scan(profileDirectory: root)

        #expect(report.isAvailable)
        #expect(report.hasBrowserState)
        let local = try #require(
            report.areas.first { $0.id == "local-storage" }
        )
        #expect(local.namespaceCount == 1)
        #expect(local.fileCount == 0)
        let indexed = try #require(
            report.areas.first { $0.id == "indexed-db" }
        )
        #expect(indexed.namespaceCount == 1)
        #expect(indexed.fileCount == 0)
    }

    @Test func storageSurfaceStopsAtBoundedAreaLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let localStorage = root.appendingPathComponent(
            "Default/Local Storage",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localStorage,
            withIntermediateDirectories: true
        )
        for index in 0...ProfileStorageSurfaceScanner.maximumEntriesPerArea {
            try Data("x".utf8).write(
                to: localStorage.appendingPathComponent("entry-\(index).ldb")
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let report = ProfileStorageSurfaceScanner.scan(profileDirectory: root)
        let local = try #require(
            report.areas.first { $0.id == "local-storage" }
        )

        #expect(!local.isAvailable)
        #expect(local.fileCount == ProfileStorageSurfaceScanner.maximumEntriesPerArea)
        #expect(local.issue == "Слишком много записей для быстрой проверки.")
    }

    @Test func storageSurfaceIgnoresSymlinkedEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let localStorage = root.appendingPathComponent(
            "Default/Local Storage",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localStorage,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: localStorage.appendingPathComponent("linked-leveldb"),
            withDestinationURL: outside
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let report = ProfileStorageSurfaceScanner.scan(profileDirectory: root)
        let local = try #require(
            report.areas.first { $0.id == "local-storage" }
        )
        #expect(local.namespaceCount == 0)
        #expect(local.fileCount == 0)
        #expect(local.isAvailable)
    }
}
