import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelaySessionAuthorityTests {
    private let mainPID: pid_t = 101
    private let childPID: pid_t = 102
    private let peer = ProxyRelayLoopbackServer.Peer(clientPort: 41000, relayPort: 42000)
    private func identity(parent: pid_t, seconds: Int64 = 100, user: uid_t = geteuid()) -> ProxyRelayOwnerProcessIdentity {
        .init(generation: .init(startSeconds: seconds, startMicroseconds: 0), userID: user, parentProcessID: parent)
    }
    private func binding(hash: String = String(repeating: "a", count: 64)) throws -> ProxyRelaySessionAuthority.Binding {
        try .init(profileID: UUID(), sessionGeneration: UUID(), runtimeExecutableSHA256: hash,
                  runtimeFrameworkSHA256: hash, configurationSHA256: hash,
                  browserPID: mainPID, browserIdentity: identity(parent: 99))
    }
    private func inspector(main: ProxyRelayOwnerProcessIdentity? = nil,
                           child: ProxyRelayOwnerProcessIdentity? = nil,
                           children: [pid_t]? = [102], mainCode: Bool = true,
                           helperCode: Bool = true, socket: Bool = true) -> ProxyRelaySessionAuthority.Inspector {
        let mainValue = main ?? identity(parent: 99), childValue = child ?? identity(parent: mainPID)
        return .init(identity: { pid in pid == 101 ? mainValue : childValue }, children: { _ in children },
                     mainCode: { _, _ in mainCode }, helperCode: { _, _ in helperCode },
                     socket: { _, _, peer in socket && peer.clientPort == 41000 && peer.relayPort == 42000 })
    }

    @Test func exactOwnedProfileSocketIsAdmittedAndRevocationIsPermanent() throws {
        let authority = try ProxyRelaySessionAuthority(binding: binding(), inspector: inspector())
        #expect(authority.admits(peer))
        authority.revoke()
        #expect(!authority.admits(peer)); authority.revoke(); #expect(!authority.admits(peer))
    }
    @Test func managerExitReparentingPreservesTheBrowserGeneration() throws {
        let authority = try ProxyRelaySessionAuthority(binding: binding(), inspector: inspector(main: identity(parent: 1)))
        #expect(authority.admits(peer))
    }
    @Test func foreignGenerationUIDParentCodeAndSocketAreRefused() throws {
        let controls = [
            inspector(main: identity(parent: 99, seconds: 101)),
            inspector(main: identity(parent: 99, user: geteuid() + 1)),
            inspector(child: identity(parent: 999)),
            inspector(child: identity(parent: mainPID, user: geteuid() + 1)),
            inspector(mainCode: false), inspector(helperCode: false), inspector(socket: false),
            inspector(children: nil), inspector(children: []), inspector(children: [102, 102]),
            inspector(children: [101]), inspector(children: [0]),
            inspector(children: Array(102...614)), inspector(children: [102, 103])
        ]
        for control in controls {
            let authority = try ProxyRelaySessionAuthority(binding: binding(), inspector: control)
            #expect(!authority.admits(peer))
        }
    }
    @Test func wrongOrZeroPeerPortsCannotBorrowAnObservedSocket() throws {
        let authority = try ProxyRelaySessionAuthority(binding: binding(), inspector: inspector())
        for candidate in [ProxyRelayLoopbackServer.Peer(clientPort: 0, relayPort: 42000),
                          .init(clientPort: 41000, relayPort: 0), .init(clientPort: 41001, relayPort: 42000),
                          .init(clientPort: 41000, relayPort: 42001)] { #expect(!authority.admits(candidate)) }
    }
    @Test func malformedHashesDoNotCreateAuthority() throws {
        for hash in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                     String(repeating: "G", count: 64), String(repeating: "A", count: 64)] {
            #expect(throws: ProxyRelaySessionAuthority.Failure.invalidBinding) { try binding(hash: hash) }
        }
    }
    @Test func appleChildAPIIsDecodedAsPIDCountRatherThanByteCount() {
        #expect(ProxyRelaySessionAuthority.decodedChildren([102, 0, 0, 0], count: 1) == [102])
        #expect(ProxyRelaySessionAuthority.decodedChildren([102, 103, 104, 105, 0], count: 4) == [102, 103, 104, 105])
        #expect(ProxyRelaySessionAuthority.decodedChildren([0], count: 0) == [])
        for (buffer, count) in [([pid_t](repeating: 0, count: 514), Int32(513)),
                                ([102], Int32(1)), ([102, 102, 0], Int32(2)),
                                ([0, 0], Int32(1)), ([102, 0], Int32(-1))] {
            #expect(ProxyRelaySessionAuthority.decodedChildren(buffer, count: count) == nil)
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var reads = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; reads += 1; return reads }
    }
    @Test func unrelatedSocketsNeverTriggerHelperSignatureWork() throws {
        let main = identity(parent: 99), child = identity(parent: mainPID), signatures = Counter()
        let checks = ProxyRelaySessionAuthority.Inspector(identity: { $0 == 101 ? main : child },
            children: { _ in Array(102...613) }, mainCode: { _, _ in true },
            helperCode: { _, _ in _ = signatures.next(); return true }, socket: { pid, _, _ in pid == 102 })
        let authority = try ProxyRelaySessionAuthority(binding: binding(), inspector: checks)
        #expect(authority.admits(peer))
        #expect(signatures.next() == 3) // one match plus its final validation
    }
    @Test func samePIDExecOrSocketChangeBeforeFinalAdmissionIsRefused() throws {
        let main = identity(parent: 99), child = identity(parent: mainPID)
        for vector in ["main", "child", "socket", "code"] {
            let counter = Counter()
            let checks = ProxyRelaySessionAuthority.Inspector(identity: { pid in
                if vector == "main", pid == 101, counter.next() > 1 { return nil }
                if vector == "child", pid == 102, counter.next() > 1 { return nil }
                return pid == 101 ? main : child
            }, children: { _ in [102] }, mainCode: { _, _ in true }, helperCode: { _, _ in
                vector != "code" || counter.next() == 1
            }, socket: { _, _, _ in vector != "socket" || counter.next() == 1 })
            let authority = try ProxyRelaySessionAuthority(binding: binding(), inspector: checks)
            #expect(!authority.admits(peer))
        }
    }
}
