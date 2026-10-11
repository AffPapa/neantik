import CryptoKit
import DirectZipCodec
import Foundation

enum CRXSyntheticPackageFixtures {
    // Own ephemeral software key only; no Keychain or external extension code.
    static func signed(_ archive: Data, key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) throws -> Data {
        let spki = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                         0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0]) + key.publicKey.x963Representation
        let header = field(1, Data(SHA256.hash(data: spki).prefix(16)))
        let message = Data("CRX3 SignedData\0".utf8) + le(UInt32(header.count)) + header + archive
        let proof = field(1, spki) + field(2, try key.signature(for: message).derRepresentation)
        let metadata = field(3, proof) + field(10000, header)
        return Data("Cr24".utf8) + le(3) + le(UInt32(metadata.count)) + metadata + archive
    }
    static func field(_ number: UInt32, _ data: Data) -> Data { varint((number << 3) | 2) + varint(UInt32(data.count)) + data }
    static func varint(_ value: UInt32) -> Data {
        var value = value, result = Data()
        while value >= 128 { result.append(UInt8(value & 127) | 128); value >>= 7 }; result.append(UInt8(value)); return result
    }
    static func le(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func small(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    static func zip(_ entries: [(String, Data)], mode: UInt32 = 0o100644, deflatedPayload: Bool = false) -> Data {
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
