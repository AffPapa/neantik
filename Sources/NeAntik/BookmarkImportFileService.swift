import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum BookmarkImportFileService {
    /// Bounded no-follow read of an explicitly selected regular file. A pipe,
    /// source replacement, growth or in-place edit never becomes a valid import.
    static func read(_ url: URL, afterRead: () throws -> Void = {}) throws -> BookmarkImportDocument {
        guard url.isFileURL else { throw BookmarkImportError.invalidFormat }
        var parentURL = url.deletingLastPathComponent()
        for alias in ["var", "tmp"] where parentURL.path.hasPrefix("/" + alias + "/") {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: "/" + alias)
            guard target == "private/" + alias || target == "/private/" + alias else { throw BookmarkImportError.invalidFormat }
            parentURL = URL(fileURLWithPath: "/private" + parentURL.path)
        }
        try BackupFS.validateName(url.lastPathComponent)
        let parent = try BackupFS.directory(parentURL); defer { Darwin.close(parent) }
        let parentIdentity = try BackupFS.identity(parent)
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BookmarkImportError.invalidFormat }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & 0o170000 == 0o100000, before.st_nlink == 1, before.st_size > 0 else { throw BookmarkImportError.invalidFormat }
        guard before.st_size <= BookmarkImportDocument.maximumBytes else { throw BookmarkImportError.limitExceeded }
        var data = Data(), offset: Int64 = 0
        while offset < before.st_size {
            try Task.checkCancellation()
            let count = min(65_536, Int(before.st_size - offset))
            var buffer = [UInt8](repeating: 0, count: count)
            let received = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
            guard received > 0 else { throw BookmarkImportError.invalidFormat }
            data.append(contentsOf: buffer.prefix(received)); offset += Int64(received)
        }
        try afterRead()
        try BackupFS.validateDirectoryPath(parentURL, parentIdentity)
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino, named.st_mode & 0o170000 == 0o100000,
              try BackupFS.entry(parent, url.lastPathComponent)?.sameObject(.init(before)) == true else { throw BookmarkImportError.invalidFormat }
        return try BookmarkImportDocument.parse(data)
    }

    @MainActor static func select() async throws -> BookmarkImportDocument? {
        let panel = NSOpenPanel()
        panel.title = "Создать профиль из закладок"
        panel.message = "Выбери экспорт закладок HTML или файл Bookmarks Chromium. После просмотра будет создан новый профиль."
        panel.allowedContentTypes = [.html, .json, .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let worker = Task.detached(priority: .userInitiated) { try read(url) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
