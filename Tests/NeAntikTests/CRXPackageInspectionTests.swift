import CryptoKit
import Darwin
import DirectZipCodec
import Foundation
import Testing
@testable import NeAntik

struct CRXPackageInspectionTests {
    private let manifest = Data(#"{"manifest_version":3,"name":"QA extension","version":"1.0","permissions":["storage"],"host_permissions":["https://example.com/*"],"optional_permissions":["tabs"]}"#.utf8)

    @Test(arguments: [0, 1, 2]) func publishedChromiumPackagesVerifyCompleteArchive(_ fixture: Int) throws {
        let packages = [CRX3SignatureFixtures.valid_no_publisher_crx3,
                        CRX3SignatureFixtures.valid_publisher_crx3,
                        CRX3SignatureFixtures.valid_test_publisher_crx3]
        let result = try CRXPackageInspection.inspect(packages[fixture])
        #expect(result.manifestVersion == 2)
        #expect(result.entryCount > 0 && result.expandedBytes > 0)
        let proof = try CRX3SignatureVerifier.verify(packages[fixture])
        #expect(result.packageSHA256 == proof.packageSHA256)
    }

    @Test func signedMV3PreviewContainsAuthenticatedRequestedPermissions() throws {
        let package = try signed(zip([("manifest.json", manifest), ("scripts/a.js", Data("// inert QA".utf8))]))
        let result = try CRXPackageInspection.inspect(package)
        #expect(result.name == "QA extension" && result.version == "1.0")
        #expect(result.permissions == ["storage", "https://example.com/*"])
        #expect(result.optionalPermissions == ["tabs"] && result.manifestVersion == 3)
        #expect(result.entryCount == 2)
        let sliced = (Data([0xff]) + package).dropFirst()
        #expect(try CRXPackageInspection.inspect(sliced) == result)
    }

    @Test func invalidSignatureStopsBeforeArchiveInspection() throws {
        var package = try signed(zip([("manifest.json", manifest)])); package[package.count - 1] ^= 1
        #expect(throws: CRXPackageInspectionError.signature) { try CRXPackageInspection.inspect(package) }
        #expect(throws: CRXPackageInspectionError.signature) { try CRXPackageInspection.inspect(CRX3SignatureFixtures.unsigned_crx3) }
    }

    @Test(arguments: ["../manifest.json", "/manifest.json", "x//file", "x/../file", "x\\file", "C:file", "x/\u{0}file"])
    func validDeveloperSignatureDoesNotAuthorizeUnsafePaths(_ name: String) throws {
        let package = try signed(zip([("manifest.json", manifest), (name, Data())]))
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(package) }
    }

    @Test func duplicateCollisionAncestorAndLinksAreRejected() throws {
        for entries in [ [("manifest.json", manifest), ("manifest.json", manifest)],
                         [("manifest.json", manifest), ("Manifest.json", manifest)],
                         [("manifest.json", manifest), ("scripts", Data()), ("scripts/a.js", Data())],
                         [("manifest.json", manifest), ("dir/a", Data()), ("Dir/b", Data())] ] {
            #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(signed(zip(entries))) }
        }
        let link = zip([("manifest.json", manifest), ("link", Data("../outside".utf8))], mode: 0o120777)
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(signed(link)) }
    }

    @Test func crcOfNonManifestAndRecordLayoutAreNotSkipped() throws {
        let archive = zip([("manifest.json", manifest), ("payload", Data("test".utf8))])
        var damaged = archive
        let position = 30 + "manifest.json".utf8.count + manifest.count + 30 + "payload".utf8.count
        damaged[position] ^= 1
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(signed(damaged)) }
        for change in [0, archive.count - 22, archive.count - 6] {
            var invalid = archive; invalid[change] ^= 1
            #expect(throws: (any Error).self) { try CRXPackageInspection.inspect(signed(invalid)) }
        }
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(signed(archive + archive)) }
    }

    @Test func signedDeflatedPayloadAndDescriptorMustAgree() throws {
        let archive = zip([("manifest.json", manifest), ("payload", Data("hello".utf8))], deflatedPayload: true)
        #expect(try CRXPackageInspection.inspect(signed(archive)).entryCount == 2)
        let descriptor = 30 + "manifest.json".utf8.count + manifest.count + 30 + "payload".utf8.count + 7
        var conflicting = archive; conflicting[descriptor + 4] ^= 1
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(signed(conflicting)) }
        var damaged = archive; damaged[descriptor - 6] ^= 1
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(signed(damaged)) }
    }

    @Test(arguments: [#"{"name":"one","name":"two","version":"1","manifest_version":3}"#,
        #"{"name":"one","\u006eame":"two","version":"1","manifest_version":3}"#,
        #"{"name":"one","version":"1","manifest_version":true}"#,
        #"{"name":"one","version":"1","manifest_version":3,"permissions":[true]}"#,
        #"{"name":"one","version":"1","manifest_version":3,"permissions":["tabs\u0000"]}"#])
    func ambiguousAndMalformedManifestCannotProducePreview(_ json: String) throws {
        #expect(throws: CRXPackageInspectionError.manifest) {
            try CRXPackageInspection.inspect(signed(zip([("manifest.json", Data(json.utf8))])))
        }
    }

    @Test func rawDeflateChecksLengthCRCTrailingBytesAndCancellation() {
        let compressed = Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00]), expected = Data("hello".utf8)
        let crc = expected.withUnsafeBytes { neantik_zip_crc32($0.baseAddress, $0.count) }
        func decode(_ bytes: Data, _ count: UInt64, _ hash: UInt32, cancelled: Bool = false) -> Int32 {
            bytes.withUnsafeBytes { input in
                var cancellation = cancelled
                return withUnsafeMutablePointer(to: &cancellation) { context in
                    neantik_zip_verify_memory(input.baseAddress, input.count, count, 8, hash, nil, 0,
                        { $0!.assumingMemoryBound(to: Bool.self).pointee ? 1 : 0 }, context)
                }
            }
        }
        #expect(decode(compressed, 5, crc) == NEANTIK_ZIP_OK)
        #expect(decode(compressed, 5, crc ^ 1) == NEANTIK_ZIP_CRC)
        #expect(decode(compressed, 4, crc) == NEANTIK_ZIP_LIMIT)
        #expect(decode(compressed + Data([0]), 5, crc) == NEANTIK_ZIP_INVALID)
        #expect(decode(Data(compressed.dropLast()), 5, crc) == NEANTIK_ZIP_INVALID)
        #expect(decode(compressed, 5, crc, cancelled: true) == NEANTIK_ZIP_CANCELLED)
        #expect(decode(compressed, 256 * 1024 * 1024 + 1, crc) == NEANTIK_ZIP_LIMIT)
    }

    @Test func cancellationDuringStoredDecodingStopsBeforeCompletion() {
        let content = Data(repeating: 0x5a, count: 1024 * 1024)
        var checks = 0
        let status = content.withUnsafeBytes { bytes in
            withUnsafeMutablePointer(to: &checks) { context in
                neantik_zip_verify_memory(bytes.baseAddress, bytes.count, UInt64(bytes.count), 0, 0, nil, 0,
                    { context in
                        let count = context!.assumingMemoryBound(to: Int.self)
                        count.pointee += 1; return count.pointee >= 3 ? 1 : 0
                    }, context)
            }
        }
        #expect(status == NEANTIK_ZIP_CANCELLED && checks == 3)
    }

    @Test func selectedFileHasNoFollowSnapshotAndReplacementControls() throws {
        let parent = URL(fileURLWithPath: "/private/tmp/neantik-crx-inspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("synthetic.crx"), package = try signed(zip([("manifest.json", manifest)]))
        try package.write(to: url)
        #expect(try CRXPackageInspection.read(url).name == "QA extension")
        #expect(throws: CRXPackageInspectionError.changed) {
            try CRXPackageInspection.read(url) { try package.write(to: url, options: .atomic) }
        }
        #expect(throws: CRXPackageInspectionError.changed) {
            try CRXPackageInspection.read(url) {
                let fd = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW); defer { Darwin.close(fd) }
                let bytes = package
                let count = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
                #expect(count == package.count)
            }
        }
        let link = parent.appendingPathComponent("link.crx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: CRXPackageInspectionError.unsafeFile) { try CRXPackageInspection.read(link) }
        let hard = parent.appendingPathComponent("hard.crx")
        try FileManager.default.linkItem(at: url, to: hard)
        #expect(throws: CRXPackageInspectionError.unsafeFile) { try CRXPackageInspection.read(url) }
    }

    @Test func cancelledInspectionNeverReturnsLateSuccess() async throws {
        let package = try signed(zip([("manifest.json", manifest)]))
        let worker = Task { while !Task.isCancelled { await Task.yield() }; return try CRXPackageInspection.inspect(package) }
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
    }

    // Own ephemeral software key only; no Keychain or external extension code.
    private func signed(_ archive: Data) throws -> Data {
        let key = P256.Signing.PrivateKey()
        let spki = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                         0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0]) + key.publicKey.x963Representation
        let header = field(1, Data(SHA256.hash(data: spki).prefix(16)))
        let message = Data("CRX3 SignedData\0".utf8) + le(UInt32(header.count)) + header + archive
        let proof = field(1, spki) + field(2, try key.signature(for: message).derRepresentation)
        let metadata = field(3, proof) + field(10000, header)
        return Data("Cr24".utf8) + le(3) + le(UInt32(metadata.count)) + metadata + archive
    }
    private func field(_ number: UInt32, _ data: Data) -> Data { varint((number << 3) | 2) + varint(UInt32(data.count)) + data }
    private func varint(_ value: UInt32) -> Data {
        var value = value, result = Data()
        while value >= 128 { result.append(UInt8(value & 127) | 128); value >>= 7 }; result.append(UInt8(value)); return result
    }
    private func le(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func small(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private func zip(_ entries: [(String, Data)], mode: UInt32 = 0o100644, deflatedPayload: Bool = false) -> Data {
        var local = Data(), central = Data()
        for (name, content) in entries {
            let raw = Data(name.utf8), crc = content.withUnsafeBytes { neantik_zip_crc32($0.baseAddress, $0.count) }, offset = UInt32(local.count)
            let deflated = deflatedPayload && name == "payload", flags: UInt16 = deflated ? 0x808 : 0x800
            let packed = deflated ? Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00]) : content
            local += le(0x04034b50) + small(20) + small(flags) + small(deflated ? 8 : 0) + small(0) + small(0)
            local += le(deflated ? 0 : crc) + le(deflated ? 0 : UInt32(packed.count)) + le(deflated ? 0 : UInt32(content.count))
            local += small(UInt16(raw.count)) + small(0) + raw + packed
            if deflated { local += le(0x08074b50) + le(crc) + le(UInt32(packed.count)) + le(UInt32(content.count)) }
            central += le(0x02014b50) + small(0x314) + small(20) + small(flags) + small(deflated ? 8 : 0) + small(0) + small(0)
            central += le(crc) + le(UInt32(packed.count)) + le(UInt32(content.count)) + small(UInt16(raw.count)) + small(0) + small(0)
            central += small(0) + small(0) + le(mode << 16) + le(offset) + raw
        }
        let ending = le(0x06054b50) + small(0) + small(0) + small(UInt16(entries.count)) + small(UInt16(entries.count))
            + le(UInt32(central.count)) + le(UInt32(local.count)) + small(0)
        return local + central + ending
    }
}
