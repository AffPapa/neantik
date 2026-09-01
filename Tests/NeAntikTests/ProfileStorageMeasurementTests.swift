import Foundation
import Testing
@testable import NeAntik

struct ProfileStorageMeasurementTests {
    @Test
    func cancelledAsyncMeasurementCancelsDetachedWorker() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let task = Task {
            await Task.yield()
            return try await ProfileStorageMeasurer.measure(at: root)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func measuresNestedRegularFilesAndSkipsSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let nested = root.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 2_048).write(
            to: root.appendingPathComponent("Cookies")
        )
        try Data(repeating: 2, count: 4_096).write(
            to: nested.appendingPathComponent("index")
        )
        try Data(repeating: 3, count: 8_192).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-link"),
            withDestinationURL: outside
        )

        let usage = try ProfileStorageMeasurer.measureSynchronously(at: root)

        #expect(usage.fileCount == 2)
        #expect(usage.allocatedBytes >= 6_144)
        #expect(!usage.formattedSize.isEmpty)
    }

    @Test
    func rejectsSymbolicLinkRootAndTreatsMissingDirectoryAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root
        )

        #expect(throws: ProfileStorageMeasurementError.self) {
            try ProfileStorageMeasurer.measureSynchronously(at: link)
        }

        try FileManager.default.removeItem(at: link)
        let missing = try ProfileStorageMeasurer.measureSynchronously(at: link)
        #expect(missing == ProfileStorageUsage(allocatedBytes: 0, fileCount: 0))
    }
}
