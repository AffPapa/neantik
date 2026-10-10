import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayOwnerProtocolTests {
    private let profileID = UUID(), generation = UUID(), nonce = UUID()
    private func bootstrap(schema: Int = 1, kind: ProxyKind = .http, username: String = "fixture-user",
                           password: String = "fixture-password", hash: String = String(repeating: "a", count: 64),
                           digest: String? = nil, version: String = "156.0.8078.12", host: String = "owned.example.test", port: Int = 8000) -> ProxyRelayOwnerProtocol.Bootstrap {
        .init(schemaVersion: schema, nonce: nonce, profileID: profileID, sessionGeneration: generation, profileRevision: 4,
              kind: kind, host: host, port: port, username: username, password: password, runtimeVersion: version,
              runtimeExecutableSHA256: hash, runtimeFrameworkSHA256: hash,
              configurationSHA256: digest ?? ProxyRelayOwnerProtocol.Bootstrap.configurationDigest(profileID: profileID, revision: 4,
                                kind: kind, host: host, port: port, username: username))
    }
    @Test func bootstrapRoundtripPreservesItsExactConfigurationAndRedactsReflection() throws {
        let input = bootstrap(); try input.validate()
        let decoded = try JSONDecoder().decode(ProxyRelayOwnerProtocol.Bootstrap.self, from: JSONEncoder().encode(input))
        try decoded.validate()
        #expect(decoded.profileID == profileID); #expect(decoded.sessionGeneration == generation)
        #expect(decoded.nonce == nonce); #expect(decoded.configurationSHA256 == input.configurationSHA256)
        #expect(!String(describing: decoded).contains("fixture-user")); #expect(Mirror(reflecting: decoded).children.isEmpty)
        try bootstrap(kind: .socks5).validate(); try bootstrap(kind: .https).validate()
        try bootstrap(username: "", password: "").validate()
    }
    @Test func wrongContextMalformedHashProtocolAndCredentialDowngradeAreRefused() {
        let controls = [bootstrap(schema: 2), bootstrap(digest: String(repeating: "b", count: 64)),
                        bootstrap(hash: "a"), bootstrap(version: "156"), bootstrap(host: "host\nheader"),
                        bootstrap(port: 0), bootstrap(port: 65536), bootstrap(username: "", password: "secret"),
                        bootstrap(username: "user:ambiguous"), bootstrap(password: "bad\r\nheader"),
                        bootstrap(kind: .socks5, password: ""), bootstrap(kind: .socks5, password: String(repeating: "x", count: 256))]
        for control in controls { #expect(throws: (any Error).self) { try control.validate() } }
    }
    @Test func profileRevisionEndpointProtocolAndUserChangeTheConfigurationDigest() {
        let original = bootstrap().configurationSHA256
        for fields in [(UUID(), UInt64(4), ProxyKind.http, "owned.example.test", 8000, "fixture-user"),
                       (profileID, 5, .http, "owned.example.test", 8000, "fixture-user"),
                       (profileID, 4, .socks5, "owned.example.test", 8000, "fixture-user"),
                       (profileID, 4, .http, "other.example.test", 8000, "fixture-user"),
                       (profileID, 4, .http, "owned.example.test", 8001, "fixture-user"),
                       (profileID, 4, .http, "owned.example.test", 8000, "other-user")] {
            #expect(ProxyRelayOwnerProtocol.Bootstrap.configurationDigest(profileID: fields.0, revision: fields.1,
                kind: fields.2, host: fields.3, port: fields.4, username: fields.5) != original)
        }
    }
    @Test func bindingRequiresNonceKernelGenerationSameUIDAndOriginalManagerParent() throws {
        let input = bootstrap(), observed = ProxyRelayOwnerProcessIdentity(generation: .init(startSeconds: 100, startMicroseconds: 123),
            userID: geteuid(), parentProcessID: 200)
        let bind = ProxyRelayOwnerProtocol.Bind(schemaVersion: 1, nonce: nonce, browserPID: 201, startSeconds: 100, startMicroseconds: 123)
        try bind.validate(bootstrap: input, observed: observed, originalParentPID: 200)
        for value in [ProxyRelayOwnerProtocol.Bind(schemaVersion: 2, nonce: nonce, browserPID: 201, startSeconds: 100, startMicroseconds: 123),
                      .init(schemaVersion: 1, nonce: UUID(), browserPID: 201, startSeconds: 100, startMicroseconds: 123),
                      .init(schemaVersion: 1, nonce: nonce, browserPID: 0, startSeconds: 100, startMicroseconds: 123),
                      .init(schemaVersion: 1, nonce: nonce, browserPID: 201, startSeconds: 101, startMicroseconds: 123),
                      .init(schemaVersion: 1, nonce: nonce, browserPID: 201, startSeconds: 100, startMicroseconds: 124)] {
            #expect(throws: ProxyRelayOwnerProtocol.Failure.invalidBinding) { try value.validate(bootstrap: input, observed: observed, originalParentPID: 200) }
        }
        #expect(throws: ProxyRelayOwnerProtocol.Failure.invalidBinding) { try bind.validate(bootstrap: input, observed: observed, originalParentPID: 199) }
        let otherUser = ProxyRelayOwnerProcessIdentity(generation: observed.generation, userID: geteuid() + 1, parentProcessID: 200)
        #expect(throws: ProxyRelayOwnerProtocol.Failure.invalidBinding) { try bind.validate(bootstrap: input, observed: otherUser, originalParentPID: 200) }
    }
}
