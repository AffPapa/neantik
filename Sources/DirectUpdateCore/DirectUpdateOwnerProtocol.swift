import CryptoKit
import Darwin
import Foundation
import Security

package enum DirectUpdateOwnerProtocolError: Error, Equatable { case request, reply, binding }

/// Private pipe scalars, never policy, signature verification or install
/// authority. Init selects only an archive to inspect; trusted installed code
/// independently supplies the target, public key, version and helper pins.
package struct DirectUpdateOwnerInit: Equatable, Sendable, CustomReflectable {
    package let bytes: Data
    package var customMirror: Mirror { Mirror(self, children: [:]) }
    package var nonce: Data { bytes.subdata(in: 4..<36) }
    package var manifestSHA256: Data { bytes.subdata(in: 36..<68) }
    package var digest: Data { Data(SHA256.hash(data: bytes)) }
    package var archive: URL { URL(fileURLWithPath: String(decoding: bytes.subdata(in: 72..<archiveEnd), as: UTF8.self)) }
    private var archiveEnd: Int { 72 + Int(OwnerWire.integer(bytes, at: 68, count: 4)) }
    package var auditFrame: Data? { bytes.prefix(4) == Data("NUI2".utf8) ? Data(bytes.dropFirst(archiveEnd + 4)) : nil }
    package init(archive: URL, manifest: Data, auditIsolation: DirectUpdateAuditIsolation? = nil) throws {
        var nonce = Data(count: 32)
        guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
            throw DirectUpdateOwnerProtocolError.request
        }
        try auditIsolation?.validate()
        try self.init(archive: archive, manifest: manifest, nonce: nonce, auditFrame: auditIsolation?.bytes)
    }
    // Deterministic negative controls; no signature/authority is manufactured.
    init(archive: URL, manifest: Data, nonce: Data, auditFrame: Data? = nil) throws {
        guard archive.isFileURL, nonce.count == 32, !manifest.isEmpty, manifest.count <= 128 * 1_024 else {
            throw DirectUpdateOwnerProtocolError.request
        }
        let path = Data(archive.path.utf8)
        guard !path.isEmpty, path.count < Int(PATH_MAX) else { throw DirectUpdateOwnerProtocolError.request }
        var data = Data((auditFrame == nil ? "NUI1" : "NUI2").utf8); data.append(nonce); data.append(contentsOf: SHA256.hash(data: manifest))
        var count = UInt32(path.count).bigEndian; withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(path)
        if let auditFrame {
            try DirectUpdateAuditIsolation.validateFrameSyntax(auditFrame)
            var auditCount = UInt32(auditFrame.count).bigEndian
            withUnsafeBytes(of: &auditCount) { data.append(contentsOf: $0) }; data.append(auditFrame)
        }
        self = try Self.parse(data)
    }
    private init(bytes: Data) { self.bytes = bytes }
    package static func parse(_ input: Data) throws -> Self {
        let data = Data(input)
        guard (73..<12_288).contains(data.count),
              [Data("NUI1".utf8), Data("NUI2".utf8)].contains(data.prefix(4)) else { throw DirectUpdateOwnerProtocolError.request }
        let pathCount = Int(OwnerWire.integer(data, at: 68, count: 4)), end = 72 + pathCount
        guard (1..<Int(PATH_MAX)).contains(pathCount), end <= data.count,
              let path = String(data: data.subdata(in: 72..<end), encoding: .utf8), path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DirectUpdateOwnerProtocolError.request
        }
        if data.prefix(4) == Data("NUI1".utf8) {
            guard end == data.count else { throw DirectUpdateOwnerProtocolError.request }
        } else {
            guard end + 4 < data.count, OwnerWire.integer(data, at: end, count: 4) == data.count - end - 4 else {
                throw DirectUpdateOwnerProtocolError.request
            }
            do { try DirectUpdateAuditIsolation.validateFrameSyntax(Data(data.dropFirst(end + 4))) }
            catch { throw DirectUpdateOwnerProtocolError.request }
        }
        return .init(bytes: data)
    }
    package func validateManifest(_ manifest: Data) throws {
        guard !manifest.isEmpty, manifest.count <= 128 * 1_024,
              Data(SHA256.hash(data: manifest)) == manifestSHA256 else { throw DirectUpdateOwnerProtocolError.binding }
    }
}

/// Displayable candidate observation. Parsing does not grant permission to
/// install; the owner must retain the actual admission/stage across consent.
package struct DirectUpdateOwnerOffer: Equatable, Sendable {
    package let bytes: Data
    package var version: String { String(decoding: bytes.dropFirst(194), as: UTF8.self) }
    package var build: UInt64 { OwnerWire.integer(bytes, at: 184, count: 8) }
    package var candidateCDHash: Data { bytes.subdata(in: 164..<184) }
    package var archiveSHA256: Data { bytes.subdata(in: 100..<132) }
    package var runtimeSHA256: Data { bytes.subdata(in: 132..<164) }
    package var digest: Data { Data(SHA256.hash(data: bytes)) }
    package init(request: DirectUpdateOwnerInit, observation: DirectUpdateAdmissionObservation) throws {
        guard case .observed = observation.system.reply else { throw DirectUpdateOwnerProtocolError.reply }
        guard try OwnerWire.hash(observation.manifestSHA256) == request.manifestSHA256 else {
            throw DirectUpdateOwnerProtocolError.binding
        }
        try self.init(request: request, version: observation.version, build: UInt64(observation.build),
                      archiveSHA256: OwnerWire.hash(observation.archiveSHA256), runtimeSHA256: OwnerWire.hash(observation.runtime.runtimeSHA256),
                      candidateCDHash: observation.system.managerCDHash)
    }
    // Scalar construction for tests. A decoded offer is never install authority.
    init(request: DirectUpdateOwnerInit, version: String, build: UInt64, archiveSHA256: Data,
         runtimeSHA256: Data, candidateCDHash: Data) throws {
        guard archiveSHA256.count == 32, runtimeSHA256.count == 32, candidateCDHash.count == 20,
              build > 0, build <= UInt64(Int.max), version.utf8.count <= 32 else { throw DirectUpdateOwnerProtocolError.reply }
        var data = Data("NUO1".utf8); data.append(request.nonce); data.append(request.digest); data.append(request.manifestSHA256)
        data.append(archiveSHA256); data.append(runtimeSHA256); data.append(candidateCDHash)
        var value = build.bigEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        var count = UInt16(version.utf8.count).bigEndian; withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(contentsOf: version.utf8)
        self = try Self.parse(data, request: request)
    }
    private init(bytes: Data) { self.bytes = bytes }
    package static func parse(_ input: Data, request: DirectUpdateOwnerInit) throws -> Self {
        let data = Data(input)
        guard (199...226).contains(data.count), data.prefix(4) == Data("NUO1".utf8),
              data.subdata(in: 4..<36) == request.nonce, data.subdata(in: 36..<68) == request.digest,
              data.subdata(in: 68..<100) == request.manifestSHA256,
              OwnerWire.integer(data, at: 184, count: 8) > 0, OwnerWire.integer(data, at: 184, count: 8) <= UInt64(Int.max),
              OwnerWire.integer(data, at: 192, count: 2) == data.count - 194,
              let version = String(data: data.dropFirst(194), encoding: .utf8), OwnerWire.version(version) else {
            throw DirectUpdateOwnerProtocolError.reply
        }
        return .init(bytes: data)
    }
    package func validate(request: DirectUpdateOwnerInit, observation: DirectUpdateAdmissionObservation) throws {
        guard self == (try .init(request: request, observation: observation)) else { throw DirectUpdateOwnerProtocolError.binding }
    }
}

package enum DirectUpdateOwnerDecision: String, Sendable { case commit = "NUC2", cancel = "NUX1" }
/// A private-pipe decision binds the exact offer and session. Accepted means
/// consent received, never durable filesystem ACK or proof that manager exited.
package enum DirectUpdateOwnerConsent {
    /// Available before an offer exists. Cancellation is session-bound and
    /// acknowledgement is sent only after admission and its children drain.
    package static func earlyCancel(request: DirectUpdateOwnerInit) -> Data {
        Data("NUX0".utf8) + request.nonce + request.digest
    }
    package static func cancelled(request: DirectUpdateOwnerInit) -> Data {
        Data("NUD0".utf8) + request.nonce + request.digest
    }
    package static func command(_ decision: DirectUpdateOwnerDecision, request: DirectUpdateOwnerInit, offer: DirectUpdateOwnerOffer) throws -> Data {
        _ = try DirectUpdateOwnerOffer.parse(offer.bytes, request: request)
        return Data(decision.rawValue.utf8) + request.nonce + offer.digest
    }
    package static func parseCommand(_ bytes: Data, request: DirectUpdateOwnerInit, offer: DirectUpdateOwnerOffer) throws -> DirectUpdateOwnerDecision {
        for decision in [DirectUpdateOwnerDecision.commit, .cancel] {
            if bytes == (try command(decision, request: request, offer: offer)) { return decision }
        }
        throw DirectUpdateOwnerProtocolError.binding
    }
    package static func accepted(request: DirectUpdateOwnerInit, offer: DirectUpdateOwnerOffer) throws -> Data {
        _ = try DirectUpdateOwnerOffer.parse(offer.bytes, request: request)
        return Data("NUA1".utf8) + request.nonce + offer.digest
    }
    package static func validateAccepted(_ bytes: Data, request: DirectUpdateOwnerInit, offer: DirectUpdateOwnerOffer) throws {
        guard bytes == (try accepted(request: request, offer: offer)) else { throw DirectUpdateOwnerProtocolError.binding }
    }
}
private enum OwnerWire {
    static func integer(_ data: Data, at offset: Int, count: Int) -> UInt64 {
        data.subdata(in: offset..<(offset + count)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static func version(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            guard part.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(part), number >= 0 else { return false }
            return String(number) == part
        }
    }
    static func hash(_ string: String) throws -> Data {
        guard string.utf8.count == 64, string.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DirectUpdateOwnerProtocolError.reply
        }
        let bytes = Array(string.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map { index in
            UInt8(String(decoding: bytes[index..<(index + 2)], as: UTF8.self), radix: 16)!
        })
    }
}
