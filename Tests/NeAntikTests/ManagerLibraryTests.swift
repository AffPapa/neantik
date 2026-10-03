import Foundation
import Testing
@testable import NeAntik

struct ManagerLibraryTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("manager-library-\(UUID())") }

    @Test func templateAllowlistAndFreshIdentity() throws {
        let original = BrowserProfile(name: "private name", tags: ["Work"], note: "secret note", isPinned: true, startURL: "https://example.test/start")
        let template = try UserProfileTemplate(name: "Work", profile: original, folderID: UUID())
        let first = template.makeProfile(), second = template.makeProfile()
        #expect(first.id != original.id && first.id != second.id)
        #expect(first.identity != original.identity && first.identity != second.identity)
        #expect(first.note.isEmpty && first.proxy == nil && first.lastLaunchedAt == nil && !first.isPinned)
        let json = String(decoding: try JSONEncoder().encode(template), as: UTF8.self)
        #expect(!json.contains("identity") && !json.contains("secret note") && !json.contains("private name"))
        for url in ["https://user:password@example.test", "https://example.test/?token=secret", "https://example.test/#token", "file:///tmp/private"] {
            #expect(!UserProfileTemplate.isSafeStartURL(url))
        }
    }

    @Test func savedFiltersSurviveFolderRenameAndExplainMissingFacets() throws {
        var folder = ProfileFolder(name: "Old")
        let tag = ProfileTagID(displayName: "Work")
        let filter = try SavedWorkspaceFilter(name: "Saved", query: .init(scope: .pinned, folderFilter: .folder(folder.id), tag: tag), search: "Example")
        folder.name = "New"
        #expect(!filter.resolved(folders: [folder], tags: [tag]).adjusted)
        let missing = filter.resolved(folders: [], tags: [])
        #expect(missing.adjusted && missing.query.folderFilter == .unfiled && missing.query.tag == nil)
        #expect(missing.query.scope == .pinned)
        #expect(try JSONDecoder().decode(SavedWorkspaceFilter.self, from: JSONEncoder().encode(filter)) == filter)
    }

    @Test func repositoryFailurePreservesCommittedDocumentAndRestart() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory)
        try paths.prepareBaseDirectories()
        let repo = ManagerLibraryRepository(paths: paths)
        let filter = try SavedWorkspaceFilter(name: "One", query: .default, search: "")
        let committed = try await repo.update { $0.filters.append(filter) }
        for code in [POSIXErrorCode.ENOSPC, .EACCES] {
            let broken = ManagerLibraryRepository(paths: paths, beforeWrite: { throw POSIXError(code) })
            await #expect(throws: (any Error).self) { try await broken.update { $0.filters = [] } }
            #expect(try await ManagerLibraryRepository(paths: paths).load() == committed)
        }
        let cancelled = Task { () throws -> ManagerLibraryDocument in
            try Task.checkCancellation()
            return try await repo.update { $0.filters = [] }
        }
        cancelled.cancel()
        _ = try? await cancelled.value
    }

    @Test func failureAfterAtomicCommitReconcilesForPublicationAndRestart() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory); try paths.prepareBaseDirectories()
        let repo = ManagerLibraryRepository(paths: paths, afterWrite: { throw POSIXError(.EIO) })
        let filter = try SavedWorkspaceFilter(name: "Committed", query: .default, search: "")
        let result = try await repo.update { $0.filters.append(filter) }
        #expect(result.filters == [filter])
        #expect(try await ManagerLibraryRepository(paths: paths).load() == result)
    }

    @Test func corruptionSchemaOversizeAndSymlinkFailClosed() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory); try paths.prepareBaseDirectories()
        let file = directory.appendingPathComponent("manager-library.json")
        let repo = ManagerLibraryRepository(paths: paths)
        var future = ManagerLibraryDocument(); future.schemaVersion = 99
        for data in [Data("broken".utf8), try JSONEncoder().encode(future), Data(repeating: 65, count: ManagerLibraryDocument.maximumBytes + 1)] {
            try paths.writePrivateFile(data, to: file)
            await #expect(throws: (any Error).self) { try await repo.load() }
            await #expect(throws: (any Error).self) { try await repo.update { $0.events = [] } }
            #expect(try Data(contentsOf: file) == data)
        }
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("target.json")
        try paths.writePrivateFile(try JSONEncoder().encode(ManagerLibraryDocument()), to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await repo.update { $0.events = [] } }
    }

    @Test func concurrentRepositoriesRetainWritesAndJournalIsBoundedTyped() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(rootDirectory: directory); try paths.prepareBaseDirectories()
        let one = ManagerLibraryRepository(paths: paths), two = ManagerLibraryRepository(paths: paths)
        let first = try SavedWorkspaceFilter(name: "One", query: .default, search: "")
        let second = try SavedWorkspaceFilter(name: "Two", query: .default, search: "")
        async let a = one.update { $0.filters.append(first) }
        async let b = two.update { $0.filters.append(second) }
        _ = try await (a, b)
        #expect(try await one.load().filters.count == 2)
        let result = try await one.update { document in
            for _ in 0..<250 { document.events.append(.init(.launch, .failed)) }
            document.events = Array(document.events.suffix(200))
        }
        #expect(result.events.count == 200)
        let text = String(decoding: try JSONEncoder().encode(result.events), as: UTF8.self)
        #expect(!text.contains("URL") && !text.contains("profileID") && !text.contains("message"))
    }
}
