#if DEBUG
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayOwnerQualificationTests {
    @Test func ownedEmptyCanonicalFixtureIsAccepted() throws {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-relay-owner-qualification-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProxyRelayOwnerQualification.validatedRoot(.init(root: root.path, upstreamPort: 10000, kind: .http))
        _ = try ProxyRelayOwnerQualification.validatedRoot(.init(root: root.path, upstreamPort: 10000, kind: .socks5))
        #expect(throws: (any Error).self) { try ProxyRelayOwnerQualification.validatedRoot(.init(root: root.path, upstreamPort: 10000, kind: .https)) }
        #expect(throws: ProxyRelayOwnerQualification.Failure.invalidFixtureProtocol) { try ProxyRelayOwnerQualification.validatedRoot(.init(root: root.path, upstreamPort: 10000, kind: .http, fixtureSlot: 3)) }
        #expect(throws: ProxyRelayOwnerQualification.Failure.invalidFixtureProtocol) { try ProxyRelayOwnerQualification.validatedRoot(.init(root: root.path, upstreamPort: 10000, kind: .http, holdManagerUntilRelease: true)) }
        try Data("owned synthetic fixture".utf8).write(to: root.appendingPathComponent("existing"))
        #expect(throws: (any Error).self) { try ProxyRelayOwnerQualification.validatedRoot(.init(root: root.path, upstreamPort: 10000, kind: .http)) }
    }
    @Test func otherRootsSymlinksAndSharedPermissionsAreRejected() throws {
        for path in ["/", "/private/tmp", "/Users", "/private/tmp/../tmp/neantik-relay-owner-qualification-fake"] {
            #expect(throws: (any Error).self) { try ProxyRelayOwnerQualification.validatedRoot(.init(root: path, upstreamPort: 10000, kind: .http)) }
        }
        let root = URL(fileURLWithPath: "/private/tmp/neantik-relay-owner-qualification-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try ProxyRelayOwnerQualification.validatedRoot(.init(root: root.path, upstreamPort: 10000, kind: .http)) }
        let link = URL(fileURLWithPath: root.path + "-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(throws: (any Error).self) { try ProxyRelayOwnerQualification.validatedRoot(.init(root: link.path, upstreamPort: 10000, kind: .http)) }
    }
}
#endif
