import Darwin
import Foundation
import Testing
@testable import NeAntik

struct BookmarkImportTests {
    @Test(arguments: ["https://example.com/?a=1&b=2", "https://example.com/?a=1&amp;b=2", "https://example.com/?value=&unknown;", "https://example.com/?value=%26"])
    func nativeChromiumHTMLAttributeEscapingPreservesURL(url: String) throws {
        // Chromium EscapeString(... ATTRIBUTE_VALUE) escapes only quotes.
        // A literal ampersand in exported HREF is valid native output.
        let text = "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF=\"\(url)\">Own</A></DL>"
        let doc = try BookmarkImportDocument.parse(Data(text.utf8))
        let expected = url.replacingOccurrences(of: "&amp;", with: "&")
        #expect(doc.roots[0] == [.link("Own", expected)])
    }
    static let html = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <!-- Own synthetic export -->
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
    <DL><p><DT><H3>Project &amp; QA</H3><DL><p>
    <DT><A HREF="https://example.com/?a=1&b=2" ADD_DATE="1">Example &#x41;</A>
    </DL><p><DT><A HREF='http://example.org/'>Other</A></DL><p>
    """
    static func json(_ node: Any, version: Any = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "checksum": "source-must-not-copy", "roots": ["bookmark_bar": ["type": "folder", "children": [node]], "other": ["type": "folder", "children": []]]])
    }
    static func document() throws -> BookmarkImportDocument { try .parse(Data(html.utf8)) }
    static func paths() throws -> AppPaths {
        let p = AppPaths(rootDirectory: URL(fileURLWithPath: "/private/tmp/neantik-bookmark-tests-" + UUID().uuidString))
        try p.prepareBaseDirectories(); return p
    }
    @Test func htmlAndJSONPreserveFoldersAndURLsRegeneratingIDs() throws {
        let html = try Self.document()
        #expect(html.linkCount == 2); #expect(html.folderCount == 1)
        #expect(html.roots[0][0] == .folder("Project & QA", [.link("Example A", "https://example.com/?a=1&b=2")]))
        let json = try BookmarkImportDocument.parse(Self.json(["type": "folder", "name": "Own", "id": "source-id", "guid": "source-guid", "meta_info": ["source": "must-not-copy"], "children": [["type": "url", "name": "Test", "url": "https://example.com/", "id": "source-link"]]]))
        #expect(json.linkCount == 1); #expect(json.folderCount == 1)
        let first = try json.chromiumBytes(), second = try json.chromiumBytes()
        #expect(first != second)
        let text = String(decoding: first, as: UTF8.self)
        for secret in ["source-id", "source-guid", "source-link", "meta_info", "must-not-copy", "checksum"] { #expect(!text.contains(secret)) }
        #expect(try BookmarkImportDocument.parse(first).roots == json.roots)
    }
    @Test(arguments: ["javascript:alert(1)", "data:text/html,x", "file:///private/tmp/x", "https://user:pass@example.com/", "https://example.com/\n", "//example.com/", "https://example.com\\evil"])
    func unsupportedURLsRefuseWholeImport(url: String) throws {
        #expect(throws: BookmarkImportError.self) { try BookmarkImportDocument.parse(Self.json(["type": "url", "name": "Own", "url": url])) }
    }
    @Test(arguments: ["true", "string", "two", "null"])
    func unsupportedSchemaTypesRefused(kind: String) throws {
        let version: Any = kind == "true" ? true : kind == "string" ? "1" : kind == "two" ? 2 : NSNull()
        #expect(throws: (any Error).self) { try BookmarkImportDocument.parse(Self.json(["type": "url", "name": "Own", "url": "https://example.com"], version: version)) }
    }
    @Test(arguments: [
        "{\"version\":1,\"version\":1,\"roots\":{}}",
        "{\"version\":1,\"ver\\u0073ion\":1,\"roots\":{}}",
        "{\"version\":1,\"roots\":{\"bookmark_bar\":{},\"other\":{},\"foreign\":{}}}",
        "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF='https://example.com' HREF='https://example.org'>X</A></DL>",
        "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><SCRIPT>alert(1)</SCRIPT></DL>",
        "<!DOCTYPE NETSCAPE-Bookmark-file-1 SYSTEM 'file:///private/tmp/x'><DL></DL>",
        "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><A HREF='https://example.com'>&external;</A></DL>",
        "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><H3>Missing children</H3></DL>"
    ]) func malformedAndExecutableInputsRefused(text: String) {
        #expect(throws: (any Error).self) { try BookmarkImportDocument.parse(Data(text.utf8)) }
    }
    @Test func limitsAndEmptyRefused() throws {
        #expect(throws: BookmarkImportError.self) { try BookmarkImportDocument.parse(Data(repeating: 32, count: BookmarkImportDocument.maximumBytes + 1)) }
        var nested: Any = ["type": "url", "name": "Own", "url": "https://example.com"]
        for _ in 0..<32 { nested = ["type": "folder", "name": "Depth", "children": [nested]] }
        #expect(throws: BookmarkImportError.self) { try BookmarkImportDocument.parse(Self.json(nested)) }
        let many = ["type": "folder", "name": "Many", "children": Array(repeating: ["type": "url", "name": "Own", "url": "https://example.com"], count: 10_000)] as [String: Any]
        #expect(throws: BookmarkImportError.self) { try BookmarkImportDocument.parse(Self.json(many)) }
        #expect(throws: BookmarkImportError.self) { try BookmarkImportDocument.parse(Self.json(["type": "folder", "name": "Empty", "children": []])) }
        #expect(throws: BookmarkImportError.self) { try BookmarkImportDocument.parse(Self.json(["type": "url", "name": String(repeating: "a", count: 1_025), "url": "https://example.com"])) }
    }
    @Test(arguments: ["symlink", "fifo", "grow", "replace", "mutate"])
    func fileReadRejectsUnsafeOrChangedSource(mode: String) throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let file = paths.rootDirectory.appendingPathComponent("own-export")
        if mode == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: paths.profilesFile) }
        else if mode == "fifo" { try #require(mkfifo(file.path, 0o600) == 0) }
        else { try Data(Self.html.utf8).write(to: file) }
        #expect(throws: (any Error).self) {
            try BookmarkImportFileService.read(file, afterRead: {
                if mode == "grow" { try Data((Self.html + " ").utf8).write(to: file) }
                if mode == "mutate" { try Data(Self.html.replacingOccurrences(of: "Other", with: "Alter").utf8).write(to: file, options: []) }
                if mode == "replace" {
                    try FileManager.default.moveItem(at: file, to: paths.rootDirectory.appendingPathComponent("held"))
                    try Data(Self.html.utf8).write(to: file)
                }
            })
        }
    }
    @Test func ownBookmarksPreparedAndRollbackIsExact() throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let id = UUID(), owned = try OwnedProfileDirectory(paths: paths, profileID: id)
        try owned.prepareBrowserData(); try owned.prepareInitialBookmarks(Self.document()); try owned.validatePreparedInitialState()
        let file = paths.browserDataDirectory(for: id).appendingPathComponent("Default/Bookmarks")
        #expect(try BookmarkImportDocument.parse(Data(contentsOf: file)).linkCount == 2)
        try owned.removeEmptyOwnedDirectories()
        #expect(!FileManager.default.fileExists(atPath: paths.profileDirectory(for: id).path))
    }
    @Test(arguments: ["Default", "Bookmarks", "in-place", "unexpected"])
    func modifiedInitialBookmarksAreRetained(mode: String) throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let id = UUID(), owned = try OwnedProfileDirectory(paths: paths, profileID: id)
        try owned.prepareBrowserData(); try owned.prepareInitialBookmarks(Self.document())
        let dir = paths.browserDataDirectory(for: id).appendingPathComponent("Default"), file = dir.appendingPathComponent("Bookmarks")
        if mode == "Default" {
            try FileManager.default.moveItem(at: dir, to: paths.rootDirectory.appendingPathComponent("held"))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try Data("foreign synthetic".utf8).write(to: file)
        } else if mode == "Bookmarks" {
            try FileManager.default.moveItem(at: file, to: paths.rootDirectory.appendingPathComponent("held"))
            try Data("foreign synthetic".utf8).write(to: file)
        } else if mode == "in-place" {
            var bytes = try Data(contentsOf: file); bytes[10] ^= 1; try bytes.write(to: file, options: [])
        } else { try Data("preserve".utf8).write(to: dir.appendingPathComponent("unexpected")) }
        #expect(throws: (any Error).self) { try owned.validatePreparedInitialState() }
        #expect(throws: (any Error).self) { try owned.removeEmptyOwnedDirectories() }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
    @MainActor @Test func productImportPublishesFreshProfileAfterBookmarkWrite() async throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let store = ProfileStore(paths: paths), existing = try store.upsert(BrowserProfile(name: "Existing own"))
        let prior = try Data(contentsOf: paths.profilesFile)
        let existingPersisted = try #require(ProfileStore.readProfiles(from: paths.profilesFile).first)
        var profile = BrowserProfile(name: "Imported own"); profile.startURL = "about:blank"
        let saved = try await store.insertImportedProfilesOffMainActor([profile], folderNames: [nil], initialBookmarks: [profile.id: Self.document()])
        #expect(saved.count == 1); #expect(saved[0].proxy == nil); #expect(saved[0].startURL == "about:blank")
        #expect(saved[0].id != existing.id); #expect(saved[0].identity != existing.identity)
        // ISO8601 persistence rounds subsecond Dates. Compare with the prior
        // persisted record rather than the transient pre-encoding value.
        #expect(store.profile(withID: existing.id) == existingPersisted)
        #expect(try Data(contentsOf: paths.profilesFile) != prior)
        let reloaded = ProfileStore(paths: paths); #expect(reloaded.profiles.count == 2)
        #expect(try BookmarkImportDocument.parse(Data(contentsOf: paths.browserDataDirectory(for: profile.id).appendingPathComponent("Default/Bookmarks"))).linkCount == 2)
    }
    @Test func sourceAncestorSymlinkIsRefusedAndOwnFileReads() throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let file = paths.rootDirectory.appendingPathComponent("OwnFile")
        try Data(Self.html.utf8).write(to: file)
        #expect(try BookmarkImportFileService.read(file).linkCount == 2)
        let alias = paths.rootDirectory.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: paths.rootDirectory)
        #expect(throws: (any Error).self) { try BookmarkImportFileService.read(alias.appendingPathComponent("OwnFile")) }
    }
    @Test func actualCancellationBeforeCommitRollsBackOwnedBookmarkBytes() async throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let profile = BrowserProfile(name: "Own cancelled fixture"), document = try Self.document()
        let worker = Task.detached {
            try ProfileMetadataImportTransaction.run(paths: paths, requestedProfiles: [profile], folderNames: [nil], initialBookmarks: [profile.id: document], beforeProfilesPersist: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.profilesDirectory.path).isEmpty)
        #expect(try ProfileStore.readProfiles(from: paths.profilesFile).isEmpty)
    }
    @Test func bookmarkDescriptorBudgetIncludesPreparedFileAndDefaultDirectory() throws {
        #expect(throws: ProfileCreationDescriptorBudgetError.self) { try OwnedProfileDirectory.validateDescriptorBudget(profileCount: 10, limit: 70, openDescriptors: 5, bookmarkProfileCount: 10) }
        #expect(throws: Never.self) { try OwnedProfileDirectory.validateDescriptorBudget(profileCount: 10, limit: 90, openDescriptors: 5, bookmarkProfileCount: 10) }
    }
    @Test(arguments: ["parent", "profile", "browser", "default"])
    func lateWorldWritableOwnedDirectoryRefusesPublicationAndCleanup(component: String) throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let id = UUID(), owned = try OwnedProfileDirectory(paths: paths, profileID: id)
        try owned.prepareBrowserData(); try owned.prepareInitialBookmarks(Self.document())
        let url = component == "parent" ? paths.profilesDirectory : component == "profile" ? paths.profileDirectory(for: id) : component == "browser" ? paths.browserDataDirectory(for: id) : paths.browserDataDirectory(for: id).appendingPathComponent("Default")
        try #require(chmod(url.path, 0o777) == 0)
        #expect(throws: (any Error).self) { try owned.validatePreparedInitialState() }
        #expect(throws: (any Error).self) { try owned.removeEmptyOwnedDirectories() }
        #expect(FileManager.default.fileExists(atPath: paths.browserDataDirectory(for: id).appendingPathComponent("Default/Bookmarks").path))
    }
    @Test func maximumSupportedNodeCountIsAccepted() throws {
        let nodes = Array(repeating: ["type": "url", "name": "Own", "url": "https://example.com", "guid": "ignored-source-guid", "id": "ignored-source-id", "date_added": "1", "date_last_used": "0", "meta_info": [String: String]()], count: 10_000) as [[String: Any]]
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "roots": ["bookmark_bar": ["type": "folder", "children": nodes], "other": ["type": "folder", "children": []]]])
        let document = try BookmarkImportDocument.parse(bytes)
        #expect(document.linkCount == 10_000)
        #expect(try BookmarkImportDocument.parse(document.chromiumBytes()).linkCount == 10_000)
    }
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_BOOKMARK_RUNTIME_SEED"] == "1"))
    func prepareOwnBookmarkRuntimeProfiles() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["NEANTIK_BOOKMARK_RUNTIME_ROOT"])
        try #require(raw.hasPrefix("/private/tmp/neantik-bookmark-runtime-"))
        let root = URL(fileURLWithPath: raw)
        try #require(try FileManager.default.contentsOfDirectory(atPath: raw).isEmpty)
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let a = try await store.createProfileFromBookmarks(name: "Own imported bookmark fixture", document: Self.document())
        let b = try store.upsert(BrowserProfile(name: "Own empty bookmark fixture", startURL: "about:blank"))
        #expect(a.id != b.id); #expect(a.identity != b.identity); #expect(a.proxy == nil)
        let output: [String: Any] = ["importedProfileID": a.id.uuidString, "emptyProfileID": b.id.uuidString, "links": 2, "folders": 1, "userProfilesUsed": false, "systemKeychainUsed": false]
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: root.appendingPathComponent("fixture-profile-ids.json"))
        print("OWNED_BOOKMARK_RUNTIME_SEED_PROOF {\"newProfiles\":2,\"bookmarks\":2,\"systemKeychainUsed\":false}")
    }
    @Test(arguments: ["before-commit", "folder-commit", "cancel"])
    func failedImportRollsBackInitialBytesAndMetadata(mode: String) throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let profile = BrowserProfile(name: "Own fault")
        #expect(throws: (any Error).self) {
            try ProfileMetadataImportTransaction.run(paths: paths, requestedProfiles: [profile], folderNames: ["Own folder"], initialBookmarks: [profile.id: Self.document()], beforeProfilesPersist: {
                if mode == "before-commit" { throw BookmarkImportError.invalidFormat }
                if mode == "cancel" { throw CancellationError() }
            }, beforeOrganizationPersist: { if mode == "folder-commit" { throw BookmarkImportError.invalidFormat } })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.profilesDirectory.path).isEmpty)
        #expect(try ProfileStore.readProfiles(from: paths.profilesFile).isEmpty)
    }
    @Test func failedMetadataRollbackRetainsPublishedBookmarkData() throws {
        let paths = try Self.paths(); defer { try? FileManager.default.removeItem(at: paths.rootDirectory) }
        let profile = BrowserProfile(name: "Own retained rollback fixture")
        #expect(throws: ProfileSaveRollbackError.self) {
            try ProfileMetadataImportTransaction.run(paths: paths, requestedProfiles: [profile], folderNames: ["Own folder"], initialBookmarks: [profile.id: Self.document()], beforeOrganizationPersist: {
                // Non-privileged deterministic write failure: the own backup
                // pathname becomes a directory after primary publication.
                try FileManager.default.moveItem(at: paths.profilesBackupFile, to: paths.rootDirectory.appendingPathComponent("retained-own-metadata-backup"))
                try FileManager.default.createDirectory(at: paths.profilesBackupFile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                throw BookmarkImportError.invalidFormat
            })
        }
        #expect(try ProfileStore.readProfiles(from: paths.profilesFile).contains(where: { $0.id == profile.id }))
        let file = paths.browserDataDirectory(for: profile.id).appendingPathComponent("Default/Bookmarks")
        #expect(FileManager.default.fileExists(atPath: file.path))
        if FileManager.default.fileExists(atPath: file.path) { #expect(try BookmarkImportDocument.parse(Data(contentsOf: file)).linkCount == 2) }
    }
    @Test func structuralJSONComplexityLimitRejectsIgnoredPadding() throws {
        let data = Data(("{\"version\":1,\"padding\":[" + Array(repeating: "0", count: 200_001).joined(separator: ",") + "],\"roots\":{\"bookmark_bar\":{\"type\":\"folder\",\"children\":[{\"type\":\"url\",\"name\":\"Own\",\"url\":\"https://example.com\"}]},\"other\":{\"type\":\"folder\",\"children\":[]}}}").utf8)
        #expect(data.count < BookmarkImportDocument.maximumBytes)
        #expect(throws: BookmarkImportError.limitExceeded) { try BookmarkImportDocument.parse(data) }
    }
    @Test func actualPreCancelledJSONParseRefusesBeforeReturningDocument() async throws {
        let data = try Self.json(["type": "url", "name": "Own", "url": "https://example.com"])
        let worker = Task.detached { withUnsafeCurrentTask { $0?.cancel() }; return try BookmarkImportDocument.parse(data) }
        await #expect(throws: CancellationError.self) { try await worker.value }
    }
}
