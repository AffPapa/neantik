import CryptoKit
import Foundation
import Testing
@testable import NeAntik

struct EncryptedBackupFramingTests {
    typealias Framing = EncryptedBackupFraming
    private let password = "отдельный пароль backup 🔐"

    @Test func independentPrimitiveKnownAnswers() throws {
        // PBKDF2-HMAC-SHA256: password/salt, one round, 32 bytes. These
        // constants are also checked with Python hashlib in the delivery run.
        let derived = try Framing.pbkdf2(Data("password".utf8), salt: Data("salt".utf8), rounds: 1)
        #expect(hex(derived) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        // NIST AES-256-GCM zero key/IV/plaintext vector (16-byte plaintext).
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
        let sealed = try AES.GCM.seal(Data(repeating: 0, count: 16), using: key, nonce: nonce)
        #expect(hex(sealed.ciphertext) == "cea7403d4d606b6e074ec5d3baf39d18")
        #expect(hex(sealed.tag) == "d0d1c8a799996bf0265b98b5d48ab919")
    }

    @Test func roundTripHeaderAndRecordBindings() throws {
        let writer = try Framing.Writer(password: password)
        let other = try Framing.Writer(password: password)
        #expect(writer.header.bytes.count == 42)
        #expect(writer.header.salt != other.header.salt)
        #expect(writer.header.noncePrefix != other.header.noncePrefix)
        let reader = try Framing.Reader(headerBytes: writer.header.bytes, password: password)
        let records = [
            Framing.Record(kind: .manifest, member: 0, chunk: 0, offset: 0, payload: Data("manifest".utf8)),
            Framing.Record(kind: .file, member: 9, chunk: 2, offset: 2_097_152, payload: Data("own bytes".utf8)),
            Framing.Record(kind: .footer, member: 0, chunk: 0, offset: 0, payload: Data("footer".utf8))
        ]
        for record in records { #expect(try reader.open(writer.seal(record)) == record) }
        #expect(reader.footerOpened)
        #expect(throws: EncryptedBackupError.limitExceeded) { try writer.seal(records[0]) }
        #expect(throws: EncryptedBackupError.malformedFrame) { try reader.open(Data()) }
    }

    @Test(arguments: ["cipher", "tag", "length", "truncate", "append", "wrong-password", "wrong-salt", "wrong-prefix"])
    func tamperingFailsBeforePlaintextIsReturned(kind: String) throws {
        let writer = try Framing.Writer(password: password)
        let record = Framing.Record(kind: .file, member: 1, chunk: 0, offset: 0, payload: Data("private fixture".utf8))
        var frame = try writer.seal(record)
        var header = writer.header.bytes
        var pass = password
        switch kind {
        case "cipher": frame[6] ^= 1
        case "tag": frame[frame.count - 1] ^= 1
        case "length": frame[3] ^= 1
        case "truncate": frame.removeLast()
        case "append": frame.append(0)
        case "wrong-password": pass = "a different password"
        case "wrong-salt": header[18] ^= 1
        default: header[34] ^= 1
        }
        let reader = try Framing.Reader(headerBytes: header, password: pass)
        #expect(throws: (any Error).self) { try reader.open(frame) }
        // A bad frame cannot be skipped to reveal later valid plaintext.
        #expect(throws: EncryptedBackupError.malformedFrame) { try reader.open(try writer.seal(record)) }
    }

    @Test func reorderDuplicateAndCrossContainerSpliceFail() throws {
        let first = try Framing.Writer(password: password)
        let second = try Framing.Writer(password: password)
        let record = Framing.Record(kind: .file, member: 0, chunk: 0, offset: 0, payload: Data([7, 8]))
        let frame0 = try first.seal(record)
        let frame1 = try first.seal(record)
        #expect(frame0 != frame1)
        for badFirst in [frame1, try second.seal(record)] {
            let reader = try Framing.Reader(headerBytes: first.header.bytes, password: password)
            #expect(throws: EncryptedBackupError.authenticationFailed) { try reader.open(badFirst) }
        }
        let reader = try Framing.Reader(headerBytes: first.header.bytes, password: password)
        _ = try reader.open(frame0)
        #expect(throws: EncryptedBackupError.authenticationFailed) { try reader.open(frame0) }
    }

    @Test func formatAndAllocationLimitsAreCheckedBeforeKDFOrPayloadRead() throws {
        let writer = try Framing.Writer(password: password)
        for index in [0, 8, 10, 14] {
            var bad = writer.header.bytes; bad[index] ^= 1
            // Invalid password proves the header failure precedes KDF validation.
            #expect(throws: EncryptedBackupError.unsupportedFormat) { try Framing.Reader(headerBytes: bad, password: "x") }
        }
        #expect(throws: EncryptedBackupError.unsupportedFormat) { try Framing.Header(parsing: Data()) }
        #expect(throws: EncryptedBackupError.limitExceeded) { try Framing.Reader.validatedFrameLength(Data(repeating: 255, count: 4)) }
        #expect(throws: EncryptedBackupError.malformedFrame) { try Framing.Reader.validatedFrameLength(Data([1])) }
        #expect(throws: EncryptedBackupError.limitExceeded) {
            try writer.seal(.init(kind: .file, member: 0, chunk: 0, offset: 0,
                                 payload: Data(repeating: 0, count: Framing.maximumPayload + 1)))
        }
    }

    @Test func passwordBytesAreNotTrimmedNormalizedOrTruncated() throws {
        #expect(throws: EncryptedBackupError.passwordLength) { try Framing.Writer(password: "short") }
        #expect(throws: EncryptedBackupError.passwordLength) { try Framing.Writer(password: String(repeating: "x", count: 1025)) }
        let spaced = "  a password with spaces  "
        let writer = try Framing.Writer(password: spaced)
        let frame = try writer.seal(.init(kind: .footer, member: 0, chunk: 0, offset: 0, payload: Data()))
        let reader = try Framing.Reader(headerBytes: writer.header.bytes, password: spaced.trimmingCharacters(in: .whitespaces))
        #expect(throws: EncryptedBackupError.authenticationFailed) { try reader.open(frame) }
        let decomposed = "backup-passe\u{301}-phrase"
        let unicodeWriter = try Framing.Writer(password: decomposed)
        let unicodeFrame = try unicodeWriter.seal(.init(kind: .footer, member: 0, chunk: 0, offset: 0, payload: Data()))
        let normalizedReader = try Framing.Reader(headerBytes: unicodeWriter.header.bytes, password: decomposed.precomposedStringWithCanonicalMapping)
        #expect(throws: EncryptedBackupError.authenticationFailed) { try normalizedReader.open(unicodeFrame) }
    }

    @Test func nonzeroIndexDataSlicesAndMaximumPayloadAreHandled() throws {
        let writer = try Framing.Writer(password: password)
        let record = Framing.Record(kind: .file, member: 0, chunk: 0, offset: 0,
                                    payload: Data(repeating: 42, count: Framing.maximumPayload))
        let frame = try writer.seal(record)
        var paddedHeader = Data(repeating: 0, count: 100); paddedHeader.append(writer.header.bytes)
        var paddedFrame = Data(repeating: 0, count: 100); paddedFrame.append(frame)
        let headerSlice = paddedHeader[100..<paddedHeader.count]
        let frameSlice = paddedFrame[100..<paddedFrame.count]
        #expect(headerSlice.startIndex == 100 && frameSlice.startIndex == 100)
        let reader = try Framing.Reader(headerBytes: headerSlice, password: password)
        #expect(try Framing.Reader.validatedFrameLength(frameSlice.prefix(4)) == frame.count - 4)
        #expect(try reader.open(frameSlice) == record)
        let corruptedReader = try Framing.Reader(headerBytes: headerSlice, password: password)
        paddedFrame[paddedFrame.count - 1] ^= 1
        #expect(throws: EncryptedBackupError.authenticationFailed) { try corruptedReader.open(paddedFrame[100..<paddedFrame.count]) }
        #expect(throws: EncryptedBackupError.malformedFrame) { try corruptedReader.open(frame) }
        _ = try Framing.Writer(password: String(repeating: "é", count: 512))
        #expect(throws: EncryptedBackupError.passwordLength) { try Framing.Writer(password: String(repeating: "é", count: 512) + "x") }
    }

    @Test func counterBudgetAndAuthenticMalformedPlaintextReject() throws {
        var counter = Framing.maximumFrames - 1
        #expect(try Framing.reserveOrdinal(&counter) == Framing.maximumFrames - 1)
        #expect(counter == Framing.maximumFrames)
        #expect(throws: EncryptedBackupError.limitExceeded) { try Framing.reserveOrdinal(&counter) }
        #expect(counter == Framing.maximumFrames)
        let writer = try Framing.Writer(password: password)
        let key = SymmetricKey(data: try Framing.pbkdf2(Data(password.utf8), salt: writer.header.salt, rounds: Framing.rounds))
        var nonceData = writer.header.noncePrefix; nonceData.append(Data(repeating: 0, count: 4))
        let nonce = try AES.GCM.Nonce(data: nonceData)
        for malformedKind in [true, false] {
            var plain = Data(repeating: 0, count: Framing.recordOverhead)
            plain[0] = malformedKind ? 99 : 2
            if !malformedKind { plain[20] = 1 } // declares one byte, provides none
            let size = UInt32(plain.count + 16)
            var aad = Data("NeAntik backup framing v1\0".utf8); aad.append(writer.header.bytes)
            aad.append(Data(repeating: 0, count: 4)); aad.append(Data([0, 0, 0, UInt8(size)]))
            let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad)
            var frame = Data([0, 0, 0, UInt8(size)]); frame.append(sealed.ciphertext); frame.append(sealed.tag)
            let reader = try Framing.Reader(headerBytes: writer.header.bytes, password: password)
            #expect(throws: EncryptedBackupError.malformedFrame) { try reader.open(frame) }
        }
    }

    @Test func independentAESOpenReadsTheSpecifiedBinaryFormat() throws {
        let writer = try Framing.Writer(password: password)
        let payload = Data([10, 20, 30, 40])
        let frame = try writer.seal(.init(kind: .manifest, member: 0x10203040, chunk: 0x05060708,
                                         offset: 0x0102030405060708, payload: payload))
        // Deliberately use no Framing.Reader, header accessors, counter helper
        // or archive decoder: reconstruct the published wire fields directly.
        let header = writer.header.bytes
        #expect(header.prefix(18) == Data(Array("NABACK01".utf8) + [0, 1, 0, 9, 39, 192, 0, 16, 0, 0]))
        let salt = header.subdata(in: 18..<34)
        let key = SymmetricKey(data: try Framing.pbkdf2(Data(password.utf8), salt: salt, rounds: 600000))
        var nonce = header.subdata(in: 34..<42); nonce.append(Data([0, 0, 0, 0]))
        #expect(frame.prefix(4) == Data([0, 0, 0, 41]))
        var aad = Data("NeAntik backup framing v1\0".utf8); aad.append(header)
        aad.append(Data([0, 0, 0, 0, 0, 0, 0, 41]))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                      ciphertext: frame.subdata(in: 4..<(frame.count - 16)), tag: frame.suffix(16))
        let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        let expected = Data([1, 16, 32, 48, 64, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 4]) + payload
        #expect(plaintext == expected)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
