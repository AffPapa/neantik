import CryptoKit
import Foundation
import Security

/// Verifies the developer signature over the complete CRX3 payload. This is
/// deliberately not an installer: a signed archive may still contain unsafe
/// paths, an invalid manifest, or permissions the user has not approved.
enum CRX3SignatureVerifier {
    enum Failure: Error, Equatable {
        case invalidFormat, unsupportedVersion, limitExceeded, invalidHeader
        case missingDeveloperProof, unsupportedKey, invalidSignature
    }

    struct Verification: Equatable, Sendable {
        let extensionID: String
        let packageSHA256: String
        let archiveOffset: Int
        let verifiedProofCount: Int
        // No publisher trust, safe extraction, installation or enabled-state
        // claim follows from a developer's cryptographic signature.
        let archiveSafetyVerified = false
        let publisherTrustVerified = false
    }

    static let maximumPackageBytes = 64 * 1024 * 1024
    static let maximumHeaderBytes = 1024 * 1024
    private static let maximumProofs = 32

    /// Call off the main actor. Cancellation is checked while hashing; no
    /// network, Keychain lookup, browser preference or filesystem write occurs.
    static func verify(_ package: Data) throws -> Verification {
        try Task.checkCancellation()
        guard package.count <= maximumPackageBytes else { throw Failure.limitExceeded }
        guard package.count >= 12, package.prefix(4) == Data("Cr24".utf8) else {
            throw Failure.invalidFormat
        }
        guard littleEndian32(package, at: 4) == 3 else { throw Failure.unsupportedVersion }
        let headerLength = Int(littleEndian32(package, at: 8))
        guard headerLength <= maximumHeaderBytes else { throw Failure.limitExceeded }
        guard headerLength > 0, headerLength <= package.count - 12,
              package.count > 12 + headerLength else { throw Failure.invalidHeader }
        let archiveOffset = 12 + headerLength
        let base = package.startIndex
        let header = Data(package[(base + 12)..<(base + archiveOffset)])
        // Reject ambiguous ZIP end records in the unsigned header, matching
        // the shipping Chromium verifier's protection against ZIP confusion.
        for token in [[UInt8](arrayLiteral: 0x50, 0x4b, 0x05, 0x06),
                      [UInt8](arrayLiteral: 0x50, 0x4b, 0x06, 0x07),
                      [UInt8](arrayLiteral: 0x50, 0x4b, 0x06, 0x06)] {
            guard header.range(of: Data(token)) == nil else { throw Failure.invalidHeader }
        }
        var signedHeader: Data?
        var proofs: [(rsa: Bool, data: Data)] = []
        var reader = ProtoReader(header)
        while let field = try reader.next() {
            switch field.number {
            case 2, 3:
                guard let value = field.bytes else { throw Failure.invalidHeader }
                guard proofs.count < maximumProofs else { throw Failure.limitExceeded }
                proofs.append((field.number == 2, value))
            case 10000:
                guard signedHeader == nil, let value = field.bytes else { throw Failure.invalidHeader }
                signedHeader = value
            default: break // Unknown wire fields are bounded and validated.
            }
        }
        guard let signedHeader, !signedHeader.isEmpty, !proofs.isEmpty else {
            throw Failure.missingDeveloperProof
        }
        var signedID: Data?
        var signedReader = ProtoReader(signedHeader)
        while let field = try signedReader.next() {
            if field.number == 1 {
                guard signedID == nil, let value = field.bytes, value.count == 16 else {
                    throw Failure.invalidHeader
                }
                signedID = value
            }
        }
        guard let signedID else { throw Failure.missingDeveloperProof }
        var hash = SHA256()
        hash.update(data: Data("CRX3 SignedData\0".utf8))
        var length = UInt32(signedHeader.count).littleEndian
        withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
        hash.update(data: signedHeader)
        var packageHash = SHA256()
        packageHash.update(data: package.prefix(archiveOffset))
        for offset in stride(from: archiveOffset, to: package.count, by: 64 * 1024) {
            try Task.checkCancellation()
            let chunk = package[(base + offset)..<(base + min(offset + 64 * 1024, package.count))]
            hash.update(data: chunk)
            packageHash.update(data: chunk)
        }
        let digest = Data(hash.finalize())
        var foundDeveloper = false
        for proof in proofs {
            try Task.checkCancellation()
            let (spki, signature) = try parseProof(proof.data)
            let key = try publicKey(spki, rsa: proof.rsa)
            let algorithm: SecKeyAlgorithm = proof.rsa
                ? .rsaSignatureDigestPKCS1v15SHA256 : .ecdsaSignatureDigestX962SHA256
            // CRX3 uses PKCS#1 v1.5 here, despite an obsolete PSS comment in
            // Chromium's proto. Digest algorithms avoid hashing twice.
            guard SecKeyIsAlgorithmSupported(key, .verify, algorithm),
                  SecKeyVerifySignature(key, algorithm, digest as CFData,
                                        signature as CFData, nil) else {
                throw Failure.invalidSignature
            }
            if Data(SHA256.hash(data: spki).prefix(16)) == signedID { foundDeveloper = true }
        }
        guard foundDeveloper else { throw Failure.missingDeveloperProof }
        let id = signedID.flatMap { byte in
            [Character(UnicodeScalar(97 + Int(byte >> 4))!),
             Character(UnicodeScalar(97 + Int(byte & 15))!)]
        }
        return Verification(extensionID: String(id),
                            packageSHA256: packageHash.finalize().map { String(format: "%02x", $0) }.joined(),
                            archiveOffset: archiveOffset, verifiedProofCount: proofs.count)
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[data.startIndex + offset + $1]) << ($1 * 8)) }
    }

    private static func parseProof(_ data: Data) throws -> (Data, Data) {
        var reader = ProtoReader(data)
        var key: Data?, signature: Data?
        while let field = try reader.next() {
            if field.number == 1 {
                guard key == nil, let value = field.bytes, !value.isEmpty, value.count <= 16 * 1024 else {
                    throw Failure.invalidHeader
                }
                key = value
            } else if field.number == 2 {
                guard signature == nil, let value = field.bytes, !value.isEmpty, value.count <= 8 * 1024 else {
                    throw Failure.invalidHeader
                }
                signature = value
            }
        }
        guard let key, let signature else { throw Failure.invalidHeader }
        return (key, signature)
    }

    private static func publicKey(_ spki: Data, rsa: Bool) throws -> SecKey {
        var outer = DERReader(spki)
        let sequence = try outer.value(tag: 0x30)
        guard outer.finished else { throw Failure.unsupportedKey }
        var body = DERReader(sequence)
        var algorithm = DERReader(try body.value(tag: 0x30))
        let oid = try algorithm.value(tag: 0x06)
        let bits = try body.value(tag: 0x03)
        guard body.finished, bits.first == 0, bits.count > 1 else { throw Failure.unsupportedKey }
        let encoded: Data
        let kind: CFString
        if rsa {
            guard oid == Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]),
                  try algorithm.value(tag: 0x05).isEmpty, algorithm.finished else {
                throw Failure.unsupportedKey
            }
            encoded = Data(bits.dropFirst()) // Security accepts PKCS#1 RSA.
            var rsaWrapper = DERReader(encoded)
            var rsaValues = DERReader(try rsaWrapper.value(tag: 0x30))
            let modulus = try rsaValues.value(tag: 0x02)
            let exponent = try rsaValues.value(tag: 0x02)
            guard rsaWrapper.finished, rsaValues.finished,
                  validPositiveInteger(modulus), validPositiveInteger(exponent),
                  boundedRSAExponent(exponent) else {
                throw Failure.unsupportedKey
            }
            kind = kSecAttrKeyTypeRSA
        } else {
            guard oid == Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]),
                  try algorithm.value(tag: 0x06) == Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]),
                  algorithm.finished, bits.count == 66, bits[1] == 0x04 else {
                throw Failure.unsupportedKey
            }
            encoded = Data(bits.dropFirst()) // P-256 uncompressed X9.63 point.
            kind = kSecAttrKeyTypeECSECPrimeRandom
        }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kind,
                                        kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(encoded as CFData, attributes as CFDictionary, nil),
              let imported = SecKeyCopyAttributes(key) as? [String: Any],
              let size = imported[kSecAttrKeySizeInBits as String] as? Int,
              (rsa ? (size >= 2048 && size <= 8192) : size == 256) else {
            throw Failure.unsupportedKey
        }
        return key
    }

    private static func validPositiveInteger(_ value: Data) -> Bool {
        guard let first = value.first, first < 0x80, value.contains(where: { $0 != 0 }) else { return false }
        return value.count == 1 || first != 0 || value[value.startIndex + 1] >= 0x80
    }

    private static func boundedRSAExponent(_ value: Data) -> Bool {
        // A bounded public exponent prevents adversarial proofs from making
        // a single noncancellable Security verification arbitrarily costly.
        let bytes = value.first == 0 ? value.dropFirst() : value[...]
        guard bytes.count <= 4 else { return false }
        let exponent = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return exponent >= 3 && exponent & 1 == 1
    }

    private struct ProtoReader {
        struct Field { let number: Int; let bytes: Data? }
        private let bytes: [UInt8]
        private var offset = 0
        private var fields = 0
        init(_ data: Data) { bytes = Array(data) }
        private mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw Failure.invalidHeader }
                let byte = bytes[offset]; offset += 1
                guard index != 9 || byte <= 1 else { throw Failure.invalidHeader }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte < 0x80 {
                    guard index == 0 || byte != 0 else { throw Failure.invalidHeader }
                    return value
                }
            }
            throw Failure.invalidHeader
        }
        mutating func next() throws -> Field? {
            guard offset < bytes.count else { return nil }
            fields += 1
            guard fields <= 1024 else { throw Failure.limitExceeded }
            let tag = try varint(), number = tag >> 3
            guard number > 0, number <= 0x1fffffff else { throw Failure.invalidHeader }
            var result: Data?
            let length: Int
            switch tag & 7 {
            case 0: _ = try varint(); return Field(number: Int(number), bytes: nil)
            case 1: length = 8
            case 2:
                let count = try varint()
                guard count <= UInt64(bytes.count - offset) else { throw Failure.invalidHeader }
                length = Int(count)
                result = Data(bytes[offset..<(offset + length)])
            case 5: length = 4
            default: throw Failure.invalidHeader // Groups are unsupported.
            }
            guard length <= bytes.count - offset else { throw Failure.invalidHeader }
            offset += length
            return Field(number: Int(number), bytes: result)
        }
    }

    private struct DERReader {
        private let bytes: [UInt8]
        private var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        var finished: Bool { offset == bytes.count }
        mutating func value(tag: UInt8) throws -> Data {
            guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw Failure.unsupportedKey }
            offset += 1
            let first = bytes[offset]; offset += 1
            var length = Int(first)
            if first >= 0x80 {
                let count = Int(first & 0x7f)
                guard count > 0, count <= 4, count <= bytes.count - offset,
                      bytes[offset] != 0 else { throw Failure.unsupportedKey }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 }
                guard length >= 128 else { throw Failure.unsupportedKey }
            }
            guard length <= bytes.count - offset else { throw Failure.unsupportedKey }
            defer { offset += length }
            return Data(bytes[offset..<(offset + length)])
        }
    }
}
