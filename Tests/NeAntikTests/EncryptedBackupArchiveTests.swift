import CryptoKit
import Foundation
import Testing
@testable import NeAntik

struct EncryptedBackupArchiveTests {
    typealias Archive = EncryptedBackupArchive
    private let password = "test archive password 🔐"
    private let emptyHash = Self.hash(Data())

    @Test func roundTripDirectoriesEmptyFilesUnicodeAndMultichunkData() throws {
        let content = Data((0..<(EncryptedBackupFraming.maximumPayload + 27)).map { UInt8(truncatingIfNeeded: $0) })
        let entries: [Archive.Entry] = [
            .init(path: "Default", kind: .directory, size: 0, sha256: ""),
            .init(path: "Default/Empty", kind: .file, size: 0, sha256: emptyHash),
            .init(path: "Default/IndexedDB", kind: .directory, size: 0, sha256: ""),
            .init(path: "Default/IndexedDB/данные", kind: .file, size: UInt64(content.count), sha256: Self.hash(content))
        ]
        let manifest = fixture(entries)
        let bytes = try encode(manifest, files: [3: content])
        var beginCount = 0
        var restored = Data()
        let decoded = try decode(bytes, begin: { #expect($0 == manifest); beginCount += 1 }, write: { index, offset, data in
            #expect(index == 3 && offset == UInt64(restored.count))
            restored.append(data)
        })
        #expect(decoded == manifest && beginCount == 1 && restored == content)
        #expect(bytes.range(of: Data("данные".utf8)) == nil)
    }

    @Test func multiframeManifestAndNoFileArchive() throws {
        let entries = (0..<12_000).map {
            Archive.Entry(path: String(format: "empty-%05d-", $0) + String(repeating: "x", count: 32), kind: .file, size: 0, sha256: emptyHash)
        }
        let manifest = fixture(entries)
        let bytes = try encode(manifest, files: [:])
        #expect(bytes.count > EncryptedBackupFraming.maximumPayload)
        #expect(try decode(bytes) == manifest)
        #expect(try decode(encode(fixture([]), files: [:])).entries.isEmpty)
    }

    @Test(arguments: ["wrong-password", "footer-tag", "missing-footer", "truncated", "trailing", "duplicate", "reorder"])
    func incompleteOrTamperedContainerNeverReturnsSuccess(kind: String) throws {
        let data = Data(repeating: 53, count: EncryptedBackupFraming.maximumPayload + 13)
        let manifest = fixture([.init(path: "own-data", kind: .file, size: UInt64(data.count), sha256: Self.hash(data))])
        var bytes = try encode(manifest, files: [0: data])
        let ranges = try frameRanges(bytes)
        var pass = password
        switch kind {
        case "wrong-password": pass += "wrong"
        case "footer-tag": bytes[bytes.count - 1] ^= 1
        case "missing-footer": bytes.removeSubrange(ranges.last!)
        case "truncated": bytes.removeLast(9)
        case "trailing": bytes.append(0)
        case "duplicate": bytes.insert(contentsOf: bytes.subdata(in: ranges[1]), at: ranges[1].upperBound)
        default:
            let one = bytes.subdata(in: ranges[1]), two = bytes.subdata(in: ranges[2])
            bytes.replaceSubrange(ranges[1].lowerBound..<ranges[2].upperBound, with: two + one)
        }
        var published = false
        var stagedBytes = 0
        do {
            _ = try decode(bytes, password: pass, write: { _, _, data in stagedBytes += data.count })
            published = true
        } catch {}
        #expect(!published)
        if kind == "footer-tag" || kind == "missing-footer" || kind == "trailing" { #expect(stagedBytes == data.count) }
    }

    @Test(arguments: ["../outside", "/outside", "a//b", "a/./b", "a/../b", "a\\b", "a\u{0}b", "a\nb", String(repeating: "x", count: 256)])
    func unsafePathsAreRejectedBeforeAnyOutput(path: String) throws {
        var writes = 0
        #expect(throws: (any Error).self) {
            try Archive.encode(manifest: fixture([.init(path: path, kind: .file, size: 0, sha256: emptyHash)]), password: password,
                               readFile: { _, _, _ in Data() }, write: { _ in writes += 1 })
        }
        #expect(writes == 0)
    }

    @Test func collisionsMissingParentsSizesAndHashesRefuse() throws {
        let cases: [[Archive.Entry]] = [
            [.init(path: "A", kind: .file, size: 0, sha256: emptyHash), .init(path: "a", kind: .file, size: 0, sha256: emptyHash)],
            [.init(path: "a/b", kind: .file, size: 0, sha256: emptyHash)],
            [.init(path: "a", kind: .file, size: 0, sha256: emptyHash), .init(path: "a/b", kind: .file, size: 0, sha256: emptyHash)],
            [.init(path: "a", kind: .directory, size: 1, sha256: "")],
            [.init(path: "a", kind: .file, size: 0, sha256: String(repeating: "0", count: 64))],
            [.init(path: "a", kind: .file, size: UInt64.max, sha256: emptyHash)],
            [.init(path: "a", kind: .file, size: Archive.maximumFileBytes, sha256: emptyHash), .init(path: "b", kind: .file, size: 1, sha256: emptyHash)]
        ]
        for entries in cases { #expect(throws: (any Error).self) { try Archive.validate(fixture(entries)) } }
    }

    @Test(arguments: ["member", "chunk", "offset", "payload-size", "early-footer", "manifest-after-file"])
    func authenticatedButSemanticallyBrokenRecordsAreRejected(kind: String) throws {
        let content = Data([1, 2, 3])
        let manifest = fixture([.init(path: "own", kind: .file, size: 3, sha256: Self.hash(content))])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rawManifest = try encoder.encode(manifest)
        let writer = try EncryptedBackupFraming.Writer(password: password)
        var bytes = writer.header.bytes
        bytes.append(try writer.seal(.init(kind: .manifest, member: 0, chunk: 0, offset: 0, payload: rawManifest)))
        if kind == "early-footer" {
            bytes.append(try writer.seal(.init(kind: .footer, member: 0, chunk: 0, offset: 0, payload: Data())))
        } else {
            bytes.append(try writer.seal(.init(kind: .file, member: kind == "member" ? 1 : 0,
                chunk: kind == "chunk" ? 1 : 0, offset: kind == "offset" ? 1 : 0,
                payload: kind == "payload-size" ? Data([1]) : content)))
            if kind == "manifest-after-file" {
                bytes.append(try writer.seal(.init(kind: .manifest, member: 0, chunk: 1, offset: UInt64(rawManifest.count), payload: Data([0]))))
            }
        }
        #expect(throws: (any Error).self) { try decode(bytes) }
    }

    @Test func sourceMismatchAndWriteFailureCannotFinishArchive() throws {
        let expected = Data([1, 2])
        let manifest = fixture([.init(path: "a", kind: .file, size: 2, sha256: Self.hash(expected))])
        var bytes = Data()
        #expect(throws: EncryptedBackupError.authenticationFailed) {
            try Archive.encode(manifest: manifest, password: password, readFile: { _, _, _ in Data([9, 9]) }, write: { bytes.append($0) })
        }
        #expect(throws: (any Error).self) { try decode(bytes) }
        #expect(throws: CocoaError(.fileWriteOutOfSpace)) {
            try Archive.encode(manifest: manifest, password: password, readFile: { _, _, _ in expected }, write: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        }
    }

    @Test(arguments: [".", "...", "156..12", "156.0.8078.12.1", "156.0.8078", "１５６.0.8078.12"])
    func unsupportedVersionFailsBeforeStaging(version: String) throws {
        let manifest = fixture([], version: version)
        #expect(throws: EncryptedBackupError.unsupportedFormat) { try Archive.validate(manifest) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let writer = try EncryptedBackupFraming.Writer(password: password)
        var bytes = writer.header.bytes
        bytes.append(try writer.seal(.init(kind: .manifest, member: 0, chunk: 0, offset: 0, payload: encoder.encode(manifest))))
        bytes.append(try writer.seal(.init(kind: .footer, member: 0, chunk: 0, offset: 0, payload: Data())))
        var began = false
        #expect(throws: EncryptedBackupError.unsupportedFormat) { try decode(bytes, begin: { _ in began = true }) }
        #expect(!began)
    }

    @Test(arguments: ["manifestSHA256", "precedingStreamSHA256", "entries", "fileBytes", "recordsBeforeFooter"])
    func authenticFooterWithIncorrectCommitBindingFails(field: String) throws {
        let manifest = fixture([])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        let writer = try EncryptedBackupFraming.Writer(password: password)
        var bytes = writer.header.bytes
        bytes.append(try writer.seal(.init(kind: .manifest, member: 0, chunk: 0, offset: 0, payload: manifestData)))
        var footer: [String: Any] = ["manifestSHA256": Self.hash(manifestData), "precedingStreamSHA256": Self.hash(bytes),
                                     "entries": 0, "fileBytes": 0, "recordsBeforeFooter": 1]
        footer[field] = field.hasSuffix("SHA256") ? String(repeating: "0", count: 64) : 99
        let data = try JSONSerialization.data(withJSONObject: footer, options: [.sortedKeys, .withoutEscapingSlashes])
        bytes.append(try writer.seal(.init(kind: .footer, member: 0, chunk: 0, offset: 0, payload: data)))
        #expect(throws: EncryptedBackupError.authenticationFailed) { try decode(bytes) }
    }

    @Test(arguments: ["unknown", "duplicate", "whitespace", "fragment-member", "fragment-chunk", "fragment-offset", "short-then-next"])
    func noncanonicalManifestAndBrokenFragmentsNeverBegin(kind: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var manifestData = try encoder.encode(fixture([]))
        if kind == "unknown" { manifestData.insert(contentsOf: Data("\"unknown\":1,".utf8), at: 1) }
        if kind == "duplicate" { manifestData.insert(contentsOf: Data("\"schema\":1,".utf8), at: 1) }
        if kind == "whitespace" { manifestData.insert(32, at: 0) }
        let writer = try EncryptedBackupFraming.Writer(password: password)
        var bytes = writer.header.bytes
        bytes.append(try writer.seal(.init(kind: .manifest, member: kind == "fragment-member" ? 1 : 0,
            chunk: kind == "fragment-chunk" ? 1 : 0, offset: kind == "fragment-offset" ? 1 : 0, payload: manifestData)))
        if kind == "short-then-next" {
            bytes.append(try writer.seal(.init(kind: .manifest, member: 0, chunk: 1, offset: UInt64(manifestData.count), payload: Data([1]))))
        }
        bytes.append(try writer.seal(.init(kind: .footer, member: 0, chunk: 0, offset: 0, payload: Data())))
        var began = false
        #expect(throws: (any Error).self) { try decode(bytes, begin: { _ in began = true }) }
        #expect(!began)
    }

    @Test func ShortReadExcessEOFAndSinkErrorsNeverReturnSuccess() throws {
        let content = Data([1, 2, 3])
        let manifest = fixture([.init(path: "own", kind: .file, size: 3, sha256: Self.hash(content))])
        let bytes = try encode(manifest, files: [0: content])
        for length in [0, 1, 41, 42, 43, 45, bytes.count - 1] {
            #expect(throws: (any Error).self) { try decode(Data(bytes.prefix(length))) }
        }
        #expect(throws: EncryptedBackupError.malformedFrame) {
            try Archive.decode(password: password, read: { Data(repeating: 0, count: $0 + 1) }, begin: { _ in }, writeFile: { _, _, _ in })
        }
        #expect(throws: CancellationError.self) { try decode(bytes, begin: { _ in throw CancellationError() }) }
        #expect(throws: CocoaError(.fileWriteOutOfSpace)) { try decode(bytes, write: { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) }) }
    }

    private func fixture(_ entries: [Archive.Entry], version: String = "156.0.8078.12") -> Archive.Manifest {
        .init(profileID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, identitySHA256: emptyHash,
              runtimeExecutableSHA256: emptyHash, runtimeFrameworkSHA256: emptyHash, runtimeVersion: version,
              compatibilityScopeSHA256: emptyHash, entries: entries)
    }
    private func encode(_ manifest: Archive.Manifest, files: [Int: Data]) throws -> Data {
        var bytes = Data()
        try Archive.encode(manifest: manifest, password: password, readFile: { index, offset, count in
            try #require(files[index]).subdata(in: Int(offset)..<(Int(offset) + count))
        }, write: { bytes.append($0) })
        return bytes
    }
    private func decode(_ bytes: Data, password: String? = nil, begin: (Archive.Manifest) throws -> Void = { _ in },
                        write: (Int, UInt64, Data) throws -> Void = { _, _, _ in }) throws -> Archive.Manifest {
        var position = 0
        return try Archive.decode(password: password ?? self.password, read: { maximum in
            let end = min(bytes.count, position + min(maximum, 4_096))
            defer { position = end }
            return bytes.subdata(in: position..<end)
        }, begin: begin, writeFile: write)
    }
    private func frameRanges(_ bytes: Data) throws -> [Range<Int>] {
        var ranges: [Range<Int>] = []; var offset = EncryptedBackupFraming.headerSize
        while offset < bytes.count {
            let size = try EncryptedBackupFraming.Reader.validatedFrameLength(bytes.subdata(in: offset..<(offset + 4)))
            ranges.append(offset..<(offset + 4 + size)); offset += 4 + size
        }
        return ranges
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
