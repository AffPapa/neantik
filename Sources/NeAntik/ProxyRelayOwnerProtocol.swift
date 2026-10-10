import CryptoKit
import Darwin
import Foundation

/// Only the signed parent may send this ephemeral bootstrap over its private
/// inherited pipe. Neither this value nor encoded frames belong in logs/files.
enum ProxyRelayOwnerProtocol {
    enum Failure: Error { case invalidBootstrap, invalidBinding }
    struct Bootstrap: Codable, Sendable, CustomReflectable, CustomStringConvertible {
        let schemaVersion: Int
        let nonce: UUID
        let profileID: UUID
        let sessionGeneration: UUID
        let profileRevision: UInt64
        let kind: ProxyKind
        let host: String
        let port: Int
        let username: String
        let password: String
        let runtimeVersion: String
        let runtimeExecutableSHA256: String
        let runtimeFrameworkSHA256: String
        let configurationSHA256: String
        var description: String { "ProxyRelayBootstrap(<redacted>)" }
        var customMirror: Mirror { Mirror(self, children: [:]) }

        func validate() throws {
            guard schemaVersion == 1,
                  ManagedBrowserSessionReceipt.safeRuntimeVersion(runtimeVersion) != nil,
                  [runtimeExecutableSHA256, runtimeFrameworkSHA256, configurationSHA256].allSatisfy(Self.hash),
                  configurationSHA256 == Self.configurationDigest(profileID: profileID, revision: profileRevision,
                                                                   kind: kind, host: host, port: port, username: username)
            else { throw Failure.invalidBootstrap }
            _ = try ProxyRelayDestination(host: host, port: port)
            if username.isEmpty {
                guard password.isEmpty else { throw Failure.invalidBootstrap }
            } else {
                let credentials = try ProxyRelayCredentials(username: username, password: password)
                if kind == .socks5 { _ = try ProxyRelayWireCodec.socksAuthentication(credentials) }
            }
        }
        static func configurationDigest(profileID: UUID, revision: UInt64, kind: ProxyKind,
                                        host: String, port: Int, username: String) -> String {
            // Canonical array encodes boundaries without delimiters supplied
            // by users. Passwords are intentionally absent from the digest.
            let fields = [profileID.uuidString.lowercased(), String(revision), kind.rawValue, host, String(port), username]
            let bytes = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        private static func hash(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
    struct Bind: Codable, Sendable {
        let schemaVersion: Int
        let nonce: UUID
        let browserPID: pid_t
        let startSeconds: Int64
        let startMicroseconds: Int32
        func validate(bootstrap: Bootstrap, observed: ProxyRelayOwnerProcessIdentity, originalParentPID: pid_t) throws {
            guard schemaVersion == 1, nonce == bootstrap.nonce, browserPID > 0,
                  observed.userID == geteuid(), observed.parentProcessID == originalParentPID,
                  observed.generation.startSeconds == startSeconds,
                  observed.generation.startMicroseconds == startMicroseconds
            else { throw Failure.invalidBinding }
        }
    }
    struct Ready: Codable, Sendable { let schemaVersion: Int; let nonce: UUID; let port: UInt16 }
    struct Bound: Codable, Sendable { let schemaVersion: Int; let nonce: UUID; let bound: Bool }
    struct Commit: Codable, Sendable { let schemaVersion: Int; let nonce: UUID }
    struct Active: Codable, Sendable { let schemaVersion: Int; let nonce: UUID; let active: Bool }
}
