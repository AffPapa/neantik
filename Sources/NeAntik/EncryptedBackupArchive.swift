import CryptoKit
import Foundation

/// Versioned, bounded archive codec. Filesystem safety and atomic publication
/// belong to the restore transaction, not this codec. All sink writes must go
/// to disposable private staging until `decode` RETURNS successfully.
enum EncryptedBackupArchive {
    typealias Framing = EncryptedBackupFraming
    static let maximumManifestBytes = 16 * 1_024 * 1_024
    static let maximumEntries = 100_000
    static let maximumFileBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024

    enum EntryKind: String, Codable, Sendable { case file, directory }
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let kind: EntryKind
        let size: UInt64
        let sha256: String
    }
    struct Manifest: Codable, Equatable, Sendable {
        var schema = 1
        let profileID: UUID
        let identitySHA256: String
        let runtimeExecutableSHA256: String
        let runtimeFrameworkSHA256: String
        let runtimeVersion: String
        /// The transaction supplies a locally owned, same-Mac compatibility
        /// scope. This digest is not proof that OS-encrypted secrets migrate.
        let compatibilityScopeSHA256: String
        let entries: [Entry]
    }
    private struct Footer: Codable, Equatable {
        let manifestSHA256: String
        let precedingStreamSHA256: String
        let entries: Int
        let fileBytes: UInt64
        let recordsBeforeFooter: UInt32
    }

    static func validate(_ manifest: Manifest) throws {
        guard manifest.schema == 1, manifest.entries.count <= maximumEntries,
              [manifest.identitySHA256, manifest.runtimeExecutableSHA256, manifest.runtimeFrameworkSHA256,
               manifest.compatibilityScopeSHA256].allSatisfy(validHash),
              validRuntimeVersion(manifest.runtimeVersion) else {
            throw EncryptedBackupError.unsupportedFormat
        }
        var paths: [String: EntryKind] = [:]
        var previous = ""
        var bytes: UInt64 = 0
        var pathBytes = 0
        let emptyHash = hex(SHA256.hash(data: Data()))
        for entry in manifest.entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.isEmpty, entry.path > previous, entry.path.utf8.count <= 4_096,
                  components.count <= 32,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
                  !entry.path.contains("\\"), !entry.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  entry.size <= maximumFileBytes,
                  entry.kind == .file ? validHash(entry.sha256) : (entry.size == 0 && entry.sha256.isEmpty),
                  entry.kind != .file || entry.size != 0 || entry.sha256 == emptyHash else {
                throw EncryptedBackupError.malformedFrame
            }
            guard !["SingletonLock", "SingletonCookie", "SingletonSocket"].contains(components[0].description),
                  !components.contains(where: { $0 == ".neantik-cache-maintenance.json" || $0.hasPrefix(".neantik-cache-clearing-") }) else {
                throw EncryptedBackupError.malformedFrame
            }
            // APFS can be case-insensitive and normalize Unicode. Refuse
            // ambiguous archives even if the source volume is case-sensitive.
            let key = pathKey(entry.path)
            guard paths[key] == nil else { throw EncryptedBackupError.malformedFrame }
            if components.count > 1 {
                let parent = components.dropLast().joined(separator: "/")
                guard paths[pathKey(parent)] == .directory else { throw EncryptedBackupError.malformedFrame }
            }
            paths[key] = entry.kind
            previous = entry.path
            pathBytes += entry.path.utf8.count
            guard pathBytes <= 8 * 1_024 * 1_024 else { throw EncryptedBackupError.limitExceeded }
            let addition = bytes.addingReportingOverflow(entry.size)
            guard !addition.overflow, addition.partialValue <= maximumFileBytes else { throw EncryptedBackupError.limitExceeded }
            bytes = addition.partialValue
        }
    }

    /// readFile must use the captured, owned FD and return exactly requested
    /// bytes, revalidating source identity before and after the operation.
    static func encode(manifest: Manifest, password: String,
                       readFile: (_ index: Int, _ offset: UInt64, _ length: Int) throws -> Data,
                       write: (Data) throws -> Void) throws {
        try validate(manifest)
        let manifestBytes = try canonical(manifest)
        guard manifestBytes.count <= maximumManifestBytes else { throw EncryptedBackupError.limitExceeded }
        let writer = try Framing.Writer(password: password)
        var streamHash = SHA256()
        var records: UInt32 = 0
        var fileBytes: UInt64 = 0
        func emit(_ record: Framing.Record) throws {
            let frame = try writer.seal(record)
            try write(frame)
            streamHash.update(data: frame)
            records += 1
        }
        try write(writer.header.bytes)
        streamHash.update(data: writer.header.bytes)
        var position = 0
        var fragment: UInt32 = 0
        while position < manifestBytes.count {
            let end = min(position + Framing.maximumPayload, manifestBytes.count)
            try emit(.init(kind: .manifest, member: 0, chunk: fragment, offset: UInt64(position),
                           payload: manifestBytes.subdata(in: position..<end)))
            position = end; fragment += 1
        }
        for (index, entry) in manifest.entries.enumerated() where entry.kind == .file {
            var offset: UInt64 = 0
            var chunk: UInt32 = 0
            var fileHash = SHA256()
            while offset < entry.size {
                try Task.checkCancellation()
                let count = Int(min(UInt64(Framing.maximumPayload), entry.size - offset))
                let data = try readFile(index, offset, count)
                guard data.count == count else { throw EncryptedBackupError.malformedFrame }
                fileHash.update(data: data)
                try emit(.init(kind: .file, member: UInt32(index), chunk: chunk, offset: offset, payload: data))
                offset += UInt64(count); fileBytes += UInt64(count); chunk += 1
            }
            guard hex(fileHash.finalize()) == entry.sha256 else { throw EncryptedBackupError.authenticationFailed }
        }
        let footer = Footer(manifestSHA256: hex(SHA256.hash(data: manifestBytes)), precedingStreamSHA256: hex(streamHash.finalize()),
                            entries: manifest.entries.count, fileBytes: fileBytes, recordsBeforeFooter: records)
        try write(writer.seal(.init(kind: .footer, member: 0, chunk: 0, offset: 0, payload: canonical(footer))))
    }

    /// read may return short reads, but never more than requested; empty means
    /// actual EOF. begin/writeFile can only create PRIVATE staging objects.
    /// No success callback runs before the footer and an explicit EOF read.
    @discardableResult
    static func decode(password: String, read: (_ maximum: Int) throws -> Data,
                       begin: (Manifest) throws -> Void,
                       writeFile: (_ index: Int, _ offset: UInt64, _ data: Data) throws -> Void) throws -> Manifest {
        func exact(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                try Task.checkCancellation()
                let part = try read(count - result.count)
                guard !part.isEmpty, part.count <= count - result.count else { throw EncryptedBackupError.malformedFrame }
                result.append(part)
            }
            return result
        }
        let header = try exact(Framing.headerSize)
        let reader = try Framing.Reader(headerBytes: header, password: password)
        var streamHash = SHA256(); streamHash.update(data: header)
        var manifestBytes = Data()
        var manifestParts: UInt32 = 0
        var previousManifestSize = Framing.maximumPayload
        var manifest: Manifest?
        var records: UInt32 = 0
        var entryIndex = 0
        var offset: UInt64 = 0
        var chunk: UInt32 = 0
        var fileBytes: UInt64 = 0
        var fileHash = SHA256()
        while true {
            let prefix = try exact(4)
            let size = try Framing.Reader.validatedFrameLength(prefix)
            var frame = prefix; frame.append(try exact(size))
            let record = try reader.open(frame)
            if record.kind == .manifest {
                guard manifest == nil, record.member == 0, record.chunk == manifestParts,
                      record.offset == UInt64(manifestBytes.count), !record.payload.isEmpty,
                      previousManifestSize == Framing.maximumPayload,
                      manifestBytes.count <= maximumManifestBytes - record.payload.count else {
                    throw EncryptedBackupError.malformedFrame
                }
                manifestBytes.append(record.payload)
                previousManifestSize = record.payload.count
                manifestParts += 1
            } else {
                if manifest == nil {
                    guard manifestParts > 0 else { throw EncryptedBackupError.malformedFrame }
                    let decoded: Manifest
                    do { decoded = try JSONDecoder().decode(Manifest.self, from: manifestBytes) }
                    catch { throw EncryptedBackupError.malformedFrame }
                    try validate(decoded)
                    guard try canonical(decoded) == manifestBytes else { throw EncryptedBackupError.malformedFrame }
                    manifest = decoded
                    try begin(decoded)
                }
                let current = manifest!
                while entryIndex < current.entries.count,
                      current.entries[entryIndex].kind == .directory || current.entries[entryIndex].size == 0 {
                    entryIndex += 1
                }
                if record.kind == .footer {
                    guard entryIndex == current.entries.count, record.member == 0, record.chunk == 0,
                          record.offset == 0 else { throw EncryptedBackupError.malformedFrame }
                    let expected = Footer(manifestSHA256: hex(SHA256.hash(data: manifestBytes)),
                                          precedingStreamSHA256: hex(streamHash.finalize()), entries: current.entries.count,
                                          fileBytes: fileBytes, recordsBeforeFooter: records)
                    guard try canonical(expected) == record.payload else { throw EncryptedBackupError.authenticationFailed }
                    guard try read(1).isEmpty else { throw EncryptedBackupError.malformedFrame }
                    return current
                }
                guard record.kind == .file, entryIndex < current.entries.count,
                      record.member == UInt32(entryIndex), record.chunk == chunk, record.offset == offset else {
                    throw EncryptedBackupError.malformedFrame
                }
                let entry = current.entries[entryIndex]
                let expectedLength = Int(min(UInt64(Framing.maximumPayload), entry.size - offset))
                guard record.payload.count == expectedLength, expectedLength > 0 else { throw EncryptedBackupError.malformedFrame }
                fileHash.update(data: record.payload)
                try writeFile(entryIndex, offset, record.payload)
                offset += UInt64(expectedLength); fileBytes += UInt64(expectedLength); chunk += 1
                if offset == entry.size {
                    guard hex(fileHash.finalize()) == entry.sha256 else { throw EncryptedBackupError.authenticationFailed }
                    entryIndex += 1; offset = 0; chunk = 0; fileHash = SHA256()
                }
            }
            streamHash.update(data: frame)
            records += 1
        }
    }

    private static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validRuntimeVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 64 && parts.count == 4 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
