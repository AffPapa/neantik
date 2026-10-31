import CommonCrypto
import CryptoKit
import Foundation
import Security

enum EncryptedBackupError: Error, Equatable {
    case passwordLength, unsupportedFormat, malformedFrame, limitExceeded, authenticationFailed, entropyUnavailable
}

/// Streaming cryptographic framing only. Opening a frame does not authorize
/// publishing restored files: the archive layer must validate manifest, all
/// file hashes, the footer and true EOF before its filesystem transaction.
enum EncryptedBackupFraming {
    static let headerSize = 42
    static let maximumPayload = 1_048_576
    static let recordOverhead = 21
    static let maximumFrames: UInt32 = 200_000
    static let rounds: UInt32 = 600_000
    private static let domain = Data("NeAntik backup framing v1\0".utf8)

    enum Kind: UInt8 { case manifest = 1, file = 2, footer = 3 }
    struct Record: Equatable {
        let kind: Kind
        let member: UInt32
        let chunk: UInt32
        let offset: UInt64
        let payload: Data
    }

    struct Header: Equatable {
        let bytes: Data
        var salt: Data { slice(bytes, 18..<34) }
        var noncePrefix: Data { slice(bytes, 34..<42) }

        init(parsing bytes: Data) throws {
            guard bytes.count == headerSize,
                  bytes.prefix(8) == Data("NABACK01".utf8),
                  decode(bytes, at: 8, count: 2) == 1,
                  decode(bytes, at: 10, count: 4) == UInt64(rounds),
                  decode(bytes, at: 14, count: 4) == UInt64(maximumPayload) else {
                throw EncryptedBackupError.unsupportedFormat
            }
            self.bytes = bytes
        }

        fileprivate static func fresh() throws -> Header {
            var bytes = Data("NABACK01".utf8)
            append(1, width: 2, to: &bytes)
            append(UInt64(rounds), width: 4, to: &bytes)
            append(UInt64(maximumPayload), width: 4, to: &bytes)
            var random = Data(count: 24)
            let status = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 24, $0.baseAddress!) }
            guard status == errSecSuccess else { throw EncryptedBackupError.entropyUnavailable }
            bytes.append(random)
            return try Header(parsing: bytes)
        }
    }

    /// Counter advances before encryption: even an encryption failure cannot
    /// cause nonce reuse if a caller catches the error. Restart with a NEW
    /// writer/header after any I/O failure; never append to an existing backup.
    final class Writer {
        let header: Header
        private let key: SymmetricKey
        private var counter: UInt32 = 0
        private var finished = false
        private let lock = NSLock()

        init(password: String) throws {
            header = try Header.fresh()
            key = SymmetricKey(data: try derivePassword(password, salt: header.salt))
        }

        func seal(_ record: Record) throws -> Data {
            try Task.checkCancellation()
            lock.lock(); defer { lock.unlock() }
            guard !finished else { throw EncryptedBackupError.limitExceeded }
            guard record.payload.count <= maximumPayload else { throw EncryptedBackupError.limitExceeded }
            var plain = Data([record.kind.rawValue])
            append(UInt64(record.member), width: 4, to: &plain)
            append(UInt64(record.chunk), width: 4, to: &plain)
            append(record.offset, width: 8, to: &plain)
            append(UInt64(record.payload.count), width: 4, to: &plain)
            plain.append(record.payload)
            let ordinal = try reserveOrdinal(&counter)
            if record.kind == .footer { finished = true }
            let size = UInt32(plain.count + 16)
            let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce(header, ordinal),
                                        authenticating: aad(header, ordinal, size))
            var frame = Data()
            append(UInt64(size), width: 4, to: &frame)
            frame.append(sealed.ciphertext)
            frame.append(sealed.tag)
            return frame
        }
    }

    final class Reader {
        let header: Header
        private let key: SymmetricKey
        private var counter: UInt32 = 0
        private var failed = false
        private(set) var footerOpened = false
        private let lock = NSLock()

        init(headerBytes: Data, password: String) throws {
            // Reject attacker-selected format/cost before invoking the KDF.
            header = try Header(parsing: headerBytes)
            key = SymmetricKey(data: try derivePassword(password, salt: header.salt))
        }

        static func validatedFrameLength(_ prefix: Data) throws -> Int {
            guard prefix.count == 4 else { throw EncryptedBackupError.malformedFrame }
            let length = decode(prefix, at: 0, count: 4)
            guard length >= UInt64(recordOverhead + 16),
                  length <= UInt64(maximumPayload + recordOverhead + 16) else {
                throw EncryptedBackupError.limitExceeded
            }
            return Int(length)
        }

        func open(_ frame: Data) throws -> Record {
            try Task.checkCancellation()
            lock.lock(); defer { lock.unlock() }
            guard !failed, !footerOpened, counter < maximumFrames else { throw EncryptedBackupError.malformedFrame }
            do {
                let size = try Self.validatedFrameLength(Data(frame.prefix(4)))
                guard frame.count == 4 + size else { throw EncryptedBackupError.malformedFrame }
                let box = try AES.GCM.SealedBox(nonce: nonce(header, counter),
                                               ciphertext: slice(frame, 4..<(frame.count - 16)),
                                               tag: frame.suffix(16))
                let plain: Data
                do { plain = try AES.GCM.open(box, using: key, authenticating: aad(header, counter, UInt32(size))) }
                catch { throw EncryptedBackupError.authenticationFailed }
                guard plain.count >= recordOverhead, let kind = Kind(rawValue: plain[plain.startIndex]),
                      decode(plain, at: 17, count: 4) == UInt64(plain.count - recordOverhead) else {
                    throw EncryptedBackupError.malformedFrame
                }
                let record = Record(kind: kind, member: UInt32(decode(plain, at: 1, count: 4)),
                                    chunk: UInt32(decode(plain, at: 5, count: 4)), offset: decode(plain, at: 9, count: 8),
                                    payload: slice(plain, recordOverhead..<plain.count))
                counter += 1
                footerOpened = kind == .footer
                return record
            } catch {
                // A rejected block poisons this reader. No skipping a bad block
                // and continuing with a partial archive.
                failed = true
                throw error
            }
        }
    }

    private static func derivePassword(_ password: String, salt: Data) throws -> Data {
        let length = password.utf8.prefix(1025).count
        guard (12...1024).contains(length) else { throw EncryptedBackupError.passwordLength }
        let bytes = Data(password.utf8)
        try Task.checkCancellation()
        let result = try pbkdf2(bytes, salt: salt, rounds: rounds)
        try Task.checkCancellation()
        return result
    }

    // Internal for an independent published KDF known-answer test. Production
    // writers/readers pin the cost above and never accept it from a document.
    static func pbkdf2(_ password: Data, salt: Data, rounds: UInt32) throws -> Data {
        guard rounds > 0, !password.isEmpty, !salt.isEmpty else { throw EncryptedBackupError.unsupportedFormat }
        var output = Data(count: 32)
        let status = password.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { destination in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        pass.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        destination.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw EncryptedBackupError.unsupportedFormat }
        return output
    }

    static func reserveOrdinal(_ counter: inout UInt32) throws -> UInt32 {
        guard counter < maximumFrames else { throw EncryptedBackupError.limitExceeded }
        let ordinal = counter
        counter += 1
        return ordinal
    }

    private static func nonce(_ header: Header, _ counter: UInt32) throws -> AES.GCM.Nonce {
        var data = header.noncePrefix
        append(UInt64(counter), width: 4, to: &data)
        return try AES.GCM.Nonce(data: data)
    }
    private static func aad(_ header: Header, _ counter: UInt32, _ size: UInt32) -> Data {
        var result = domain
        result.append(header.bytes)
        append(UInt64(counter), width: 4, to: &result)
        append(UInt64(size), width: 4, to: &result)
        return result
    }
    private static func append(_ value: UInt64, width: Int, to data: inout Data) {
        for index in (0..<width).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
    private static func decode(_ bytes: Data, at offset: Int, count: Int) -> UInt64 {
        slice(bytes, offset..<(offset + count)).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private static func slice(_ bytes: Data, _ range: Range<Int>) -> Data {
        bytes.subdata(in: (bytes.startIndex + range.lowerBound)..<(bytes.startIndex + range.upperBound))
    }
}
