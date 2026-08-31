import Darwin
import Foundation

struct ProfileStorageUsage: Equatable, Sendable {
    let allocatedBytes: Int64
    let fileCount: Int

    var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: allocatedBytes,
            countStyle: .file
        )
    }
}

enum ProfileStorageMeasurementError: LocalizedError, Equatable {
    case unsafeDirectory
    case unreadable
    case tooManyEntries
    case sizeOverflow

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            "Папка данных профиля небезопасна или была заменена ссылкой."
        case .unreadable:
            "Не удалось прочитать размер папки профиля. Данные не изменялись."
        case .tooManyEntries:
            "В профиле слишком много файлов для быстрой проверки размера."
        case .sizeOverflow:
            "Не удалось корректно посчитать размер профиля."
        }
    }
}

enum ProfileStorageMeasurer {
    static let maximumEntries = 500_000

    static func measure(at directory: URL) async throws -> ProfileStorageUsage {
        try await Task.detached(priority: .utility) {
            try measureSynchronously(at: directory)
        }.value
    }

    static func measureSynchronously(
        at directory: URL
    ) throws -> ProfileStorageUsage {
        var rootMetadata = stat()
        if lstat(directory.path, &rootMetadata) != 0 {
            if errno == ENOENT {
                return ProfileStorageUsage(allocatedBytes: 0, fileCount: 0)
            }
            throw ProfileStorageMeasurementError.unreadable
        }
        guard rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw ProfileStorageMeasurementError.unsafeDirectory
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
        ]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ProfileStorageMeasurementError.unreadable
        }

        var allocatedBytes: Int64 = 0
        var fileCount = 0
        var entryCount = 0
        for case let url as URL in enumerator {
            entryCount += 1
            if entryCount > maximumEntries {
                throw ProfileStorageMeasurementError.tooManyEntries
            }
            if entryCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                throw ProfileStorageMeasurementError.unreadable
            }
            if values.isSymbolicLink == true {
                continue
            }
            guard values.isRegularFile == true else { continue }
            let bytes = values.totalFileAllocatedSize ??
                values.fileAllocatedSize ?? values.fileSize ?? 0
            guard bytes >= 0,
                  allocatedBytes <= Int64.max - Int64(bytes)
            else {
                throw ProfileStorageMeasurementError.sizeOverflow
            }
            allocatedBytes += Int64(bytes)
            fileCount += 1
        }
        if enumerationError != nil {
            throw ProfileStorageMeasurementError.unreadable
        }
        return ProfileStorageUsage(
            allocatedBytes: allocatedBytes,
            fileCount: fileCount
        )
    }
}
