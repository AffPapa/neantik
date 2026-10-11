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
        let package = try CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip([("manifest.json", manifest), ("scripts/a.js", Data("// inert QA".utf8))]))
        let result = try CRXPackageInspection.inspect(package)
        #expect(result.name == "QA extension" && result.version == "1.0")
        #expect(result.permissions == ["storage", "https://example.com/*"])
        #expect(result.optionalPermissions == ["tabs"] && result.manifestVersion == 3)
        #expect(result.entryCount == 2)
        let sliced = (Data([0xff]) + package).dropFirst()
        #expect(try CRXPackageInspection.inspect(sliced) == result)
    }

    @Test func invalidSignatureStopsBeforeArchiveInspection() throws {
        var package = try CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip([("manifest.json", manifest)])); package[package.count - 1] ^= 1
        #expect(throws: CRXPackageInspectionError.signature) { try CRXPackageInspection.inspect(package) }
        #expect(throws: CRXPackageInspectionError.signature) { try CRXPackageInspection.inspect(CRX3SignatureFixtures.unsigned_crx3) }
    }

    @Test(arguments: ["../manifest.json", "/manifest.json", "x//file", "x/../file", "x\\file", "C:file", "x/\u{0}file"])
    func validDeveloperSignatureDoesNotAuthorizeUnsafePaths(_ name: String) throws {
        let package = try CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip([("manifest.json", manifest), (name, Data())]))
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(package) }
    }

    @Test func duplicateCollisionAncestorAndLinksAreRejected() throws {
        for entries in [ [("manifest.json", manifest), ("manifest.json", manifest)],
                         [("manifest.json", manifest), ("Manifest.json", manifest)],
                         [("manifest.json", manifest), ("scripts", Data()), ("scripts/a.js", Data())],
                         [("manifest.json", manifest), ("dir/a", Data()), ("Dir/b", Data())] ] {
            #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip(entries))) }
        }
        let link = CRXSyntheticPackageFixtures.zip([("manifest.json", manifest), ("link", Data("../outside".utf8))], mode: 0o120777)
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(link)) }
    }

    @Test func crcOfNonManifestAndRecordLayoutAreNotSkipped() throws {
        let archive = CRXSyntheticPackageFixtures.zip([("manifest.json", manifest), ("payload", Data("test".utf8))])
        var damaged = archive
        let position = 30 + "manifest.json".utf8.count + manifest.count + 30 + "payload".utf8.count
        damaged[position] ^= 1
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(damaged)) }
        for change in [0, archive.count - 22, archive.count - 6] {
            var invalid = archive; invalid[change] ^= 1
            #expect(throws: (any Error).self) { try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(invalid)) }
        }
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(archive + archive)) }
    }

    @Test func signedDeflatedPayloadAndDescriptorMustAgree() throws {
        let archive = CRXSyntheticPackageFixtures.zip([("manifest.json", manifest), ("payload", Data("hello".utf8))], deflatedPayload: true)
        #expect(try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(archive)).entryCount == 2)
        let descriptor = 30 + "manifest.json".utf8.count + manifest.count + 30 + "payload".utf8.count + 7
        var conflicting = archive; conflicting[descriptor + 4] ^= 1
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(conflicting)) }
        var damaged = archive; damaged[descriptor - 6] ^= 1
        #expect(throws: CRXPackageInspectionError.archive) { try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(damaged)) }
    }

    @Test(arguments: [#"{"name":"one","name":"two","version":"1","manifest_version":3}"#,
        #"{"name":"one","\u006eame":"two","version":"1","manifest_version":3}"#,
        #"{"name":"one","version":"1","manifest_version":true}"#,
        #"{"name":"one","version":"1","manifest_version":3,"permissions":[true]}"#,
        #"{"name":"one","version":"1","manifest_version":3,"permissions":["tabs\u0000"]}"#])
    func ambiguousAndMalformedManifestCannotProducePreview(_ json: String) throws {
        #expect(throws: CRXPackageInspectionError.manifest) {
            try CRXPackageInspection.inspect(CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip([("manifest.json", Data(json.utf8))])))
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
        let url = parent.appendingPathComponent("synthetic.crx"), package = try CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip([("manifest.json", manifest)]))
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
        let package = try CRXSyntheticPackageFixtures.signed(CRXSyntheticPackageFixtures.zip([("manifest.json", manifest)]))
        let worker = Task { while !Task.isCancelled { await Task.yield() }; return try CRXPackageInspection.inspect(package) }
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
    }

}
