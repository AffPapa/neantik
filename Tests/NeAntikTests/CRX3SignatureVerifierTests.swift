import Foundation
import Testing
@testable import NeAntik

struct CRX3SignatureVerifierTests {
    @Test(arguments: [0, 1, 2])
    func verifiesRealNativeRSAAndECDSAProofs(_ fixture: Int) throws {
        let packages = [CRX3SignatureFixtures.valid_no_publisher_crx3,
                        CRX3SignatureFixtures.valid_publisher_crx3,
                        CRX3SignatureFixtures.valid_test_publisher_crx3]
        let result = try CRX3SignatureVerifier.verify(packages[fixture])
        #expect(result.extensionID == (fixture == 2 ? "jlnmailbicnpnbggmhfebbomaddckncf" : "ojjgnpkioondelmggbekfhllhdaimnho"))
        #expect(result.verifiedProofCount == (fixture == 0 ? 2 : 3))
        let expectedHashes = ["d033c510f9e4ee081ccb60ea2bf530dc2e5cb0e71085b55503c8b13b74515fe4",
                              "452552a774e76900570b93934382f51dbe6d2b3d00aed122686632500cb4dbef",
                              "bfdeea7ee548f28914141763da91e3775696de5e230744e3de8b8b37b998c1a2"]
        #expect(result.packageSHA256 == expectedHashes[fixture])
        #expect(result.archiveOffset == [1152, 1322, 1320][fixture])
        #expect(!result.archiveSafetyVerified)
        #expect(!result.publisherTrustVerified)
    }

    @Test func invalidSignatureCannotFallBackToMatchingDeveloperID() {
        var package = CRX3SignatureFixtures.valid_no_publisher_crx3
        package[package.count - 1] ^= 1
        #expect(throws: CRX3SignatureVerifier.Failure.invalidSignature) {
            try CRX3SignatureVerifier.verify(package)
        }
    }

    @Test func everyProofMustVerifyIncludingPublisherECDSA() {
        for position in CRX3SignatureFixtures.valid_publisher_crx3_signatureOffsets {
            var package = CRX3SignatureFixtures.valid_publisher_crx3
            package[position] ^= 1
            #expect(throws: CRX3SignatureVerifier.Failure.invalidSignature) {
                try CRX3SignatureVerifier.verify(package)
            }
        }
    }

    @Test func signedIDIsAuthenticated() {
        var package = CRX3SignatureFixtures.valid_no_publisher_crx3
        package[CRX3SignatureFixtures.valid_no_publisher_crx3_signedIDOffset] ^= 1
        #expect(throws: CRX3SignatureVerifier.Failure.invalidSignature) {
            try CRX3SignatureVerifier.verify(package)
        }
    }

    @Test func unsignedAndLegacyPackagesAreRejected() {
        #expect(throws: CRX3SignatureVerifier.Failure.missingDeveloperProof) {
            try CRX3SignatureVerifier.verify(CRX3SignatureFixtures.unsigned_crx3)
        }
        #expect(throws: CRX3SignatureVerifier.Failure.unsupportedVersion) {
            try CRX3SignatureVerifier.verify(CRX3SignatureFixtures.valid_crx2)
        }
    }

    @Test func truncatedAndOverflowHeadersNeverProduceVerification() {
        let package = CRX3SignatureFixtures.valid_no_publisher_crx3
        for length in [0, 3, 7, 11, 12, 100, package.count - 1] {
            #expect(throws: (any Error).self) { try CRX3SignatureVerifier.verify(Data(package.prefix(length))) }
        }
        var overflow = package
        overflow.replaceSubrange(8..<12, with: [0xff, 0xff, 0xff, 0xff])
        #expect(throws: CRX3SignatureVerifier.Failure.limitExceeded) { try CRX3SignatureVerifier.verify(overflow) }
    }

    @Test func nonzeroDataIndicesKeepTheSameCryptographicContract() throws {
        let package = CRX3SignatureFixtures.valid_publisher_crx3
        let sliced = (Data([0x7f, 0x12, 0x32]) + package).dropFirst(3)
        #expect(sliced.startIndex != 0)
        #expect(try CRX3SignatureVerifier.verify(sliced) == CRX3SignatureVerifier.verify(package))
        let malformed = (Data([0x00]) + Data("Cr24".utf8)).dropFirst()
        #expect(throws: CRX3SignatureVerifier.Failure.invalidFormat) { try CRX3SignatureVerifier.verify(malformed) }
    }

    /// Outer metadata is unsigned. Its mutation must not imply authenticated
    /// permissions, publisher origin, ZIP paths or installation provenance.
    @Test func unsignedMetadataDoesNotAcquirePublisherTrust() throws {
        let package = try appendingHeaderField(Data([0x22, 0x03, 0x61, 0x62, 0x63]))
        let verification = try CRX3SignatureVerifier.verify(package)
        #expect(verification.extensionID == "ojjgnpkioondelmggbekfhllhdaimnho")
        #expect(!verification.publisherTrustVerified)
        #expect(!verification.archiveSafetyVerified)
    }

    @Test func ambiguousZIPHeaderAndDuplicateSignedHeaderAreRejected() throws {
        let endRecord = try appendingHeaderField(Data([0x22, 0x04, 0x50, 0x4b, 0x05, 0x06]))
        #expect(throws: CRX3SignatureVerifier.Failure.invalidHeader) { try CRX3SignatureVerifier.verify(endRecord) }
        // field10000, length0; duplicates are ambiguous even when both proofs
        // of the original singular value would otherwise remain valid.
        let duplicate = try appendingHeaderField(Data([0x82, 0xf1, 0x04, 0x00]))
        #expect(throws: CRX3SignatureVerifier.Failure.invalidHeader) { try CRX3SignatureVerifier.verify(duplicate) }
        let overflowVarint = try appendingHeaderField(Data(repeating: 0xff, count: 10))
        #expect(throws: CRX3SignatureVerifier.Failure.invalidHeader) { try CRX3SignatureVerifier.verify(overflowVarint) }
    }

    @Test func duplicateProofFieldsCannotOverrideAnEarlierKeyOrSignature() throws {
        // These additional unsigned proof messages follow the valid proofs.
        // A later duplicate must be rejected, never used as an override.
        for proof in [
            Data([0x0a, 0x01, 0x00, 0x0a, 0x01, 0x01, 0x12, 0x01, 0x00]),
            Data([0x0a, 0x01, 0x00, 0x12, 0x01, 0x00, 0x12, 0x01, 0x01])
        ] {
            let package = try appendingHeaderField(Data([0x12, UInt8(proof.count)]) + proof)
            #expect(throws: CRX3SignatureVerifier.Failure.invalidHeader) {
                try CRX3SignatureVerifier.verify(package)
            }
        }
    }

    @Test func malformedWireTypesAndLengthsAreRejected() throws {
        for field in [
            Data([0x13]),                       // protobuf group, unsupported
            Data([0x10, 0x00]),                 // proof uses varint, not bytes
            Data([0x12, 0x7f, 0x00]),           // length crosses header boundary
            Data([0x22, 0x80, 0x00]),           // noncanonical length varint
            Data([0x00]),                       // field number zero
            Data([0x25, 0x00])                  // truncated fixed32 field
        ] {
            let package = try appendingHeaderField(field)
            #expect(throws: CRX3SignatureVerifier.Failure.invalidHeader) {
                try CRX3SignatureVerifier.verify(package)
            }
        }
    }

    @Test func invalidSPKINeverBecomesAReceiptFromAValidEarlierProof() throws {
        // Wrong top-level DER tag, indefinite length, truncated long length,
        // or a complete empty sequence with trailing data are not a key.
        for key in [Data([0x31, 0x00]), Data([0x30, 0x80]),
                    Data([0x30, 0x82, 0x01]), Data([0x30, 0x00, 0x00])] {
            var proof = Data([0x0a, UInt8(key.count)]) + key
            proof.append(contentsOf: [0x12, 0x01, 0x00])
            let package = try appendingHeaderField(Data([0x12, UInt8(proof.count)]) + proof)
            #expect(throws: CRX3SignatureVerifier.Failure.unsupportedKey) {
                try CRX3SignatureVerifier.verify(package)
            }
        }
    }

    @Test func oversizedInputIsRejectedBeforeParsing() {
        let package = Data(repeating: 0, count: CRX3SignatureVerifier.maximumPackageBytes + 1)
        #expect(throws: CRX3SignatureVerifier.Failure.limitExceeded) { try CRX3SignatureVerifier.verify(package) }
    }

    @Test func cancelledWorkerCannotReturnVerification() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CRX3SignatureVerifier.verify(CRX3SignatureFixtures.valid_publisher_crx3)
        }
        do { _ = try await task.value; Issue.record("Cancelled verifier returned a receipt") }
        catch { #expect(error is CancellationError) }
    }

    private func appendingHeaderField(_ bytes: Data) throws -> Data {
        let original = CRX3SignatureFixtures.valid_no_publisher_crx3
        let header = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(original[8 + $1]) << ($1 * 8)) }
        var size = (header + UInt32(bytes.count)).littleEndian
        var result = Data(original.prefix(8))
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(original[12..<(12 + Int(header))])
        result.append(bytes)
        result.append(original[(12 + Int(header))...])
        return result
    }
}
