#if DEBUG
import Darwin
import Foundation
import Testing
@testable import NeAntik

struct ProxyRelayQualificationQuitTests {
    private let uid: uid_t = 123
    private func identity(_ seconds: Int64, uid: uid_t = 123) -> ProxyRelayOwnerProcessIdentity {
        .init(generation: .init(startSeconds: seconds, startMicroseconds: 456), userID: uid, parentProcessID: 9)
    }
    private func snapshot() -> ProxyRelayQualificationQuit.Snapshot {
        let session = UUID(), profile = UUID()
        let relay = ProxyRelayLeaseReceipt(profileID: profile, sessionGeneration: session, ownerPID: 42,
            ownerStartSeconds: 200, ownerStartMicroseconds: 456, ownerUID: uid, loopbackPort: 12345,
            runtimeExecutableSHA256: String(repeating: "a", count: 64), runtimeFrameworkSHA256: String(repeating: "b", count: 64),
            configurationSHA256: String(repeating: "c", count: 64))
        return .init(lease: .init(pid: 41, executablePath: "/private/tmp/owned/Browser", browserDataPath: "/private/tmp/owned/data",
            createdAt: Date(timeIntervalSince1970: 1), schemaVersion: 3, ownerToken: session, phase: .running, relay: relay),
            browser: .init(identity(100)), owner: .init(identity(200)))
    }
    @Test func exactAuthorityRequestsOneNativeQuit() throws {
        let saved = snapshot(); var calls = 0
        try ProxyRelayQualificationQuit.request(expected: saved, currentUserID: uid,
            readLease: { saved.lease }, inspectBrowser: { identity(100) }, inspectOwner: { identity(200) },
            inspectExactProcess: { .expected }, nativeQuit: { calls += 1; return true })
        #expect(calls == 1)
    }
    @Test func privateFrameSnapshotRoundTripPreservesTheLease() throws {
        let saved = snapshot()
        let bytes = try JSONEncoder().encode(saved)
        let frame = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes))
        #expect(try JSONDecoder().decode(ProxyRelayQualificationQuit.Snapshot.self, from: frame) == saved)
    }
    @Test func privateTmpAliasUsesTheSamePathContractAsLaunch() {
        let data = URL(fileURLWithPath: "/private/tmp/neantik-relay-owner-qualification-path-control/Profiles/OWNED/BrowserData", isDirectory: true)
        let saved = BrowserProcessLock(pid: 41, executablePath: "/owned/Browser",
            browserDataPath: data.standardizedFileURL.path, createdAt: Date())
        #expect(ProxyRelayQualificationQuit.matchesDataPath(saved, expected: data))
        #expect(!ProxyRelayQualificationQuit.matchesDataPath(saved, expected: data.deletingLastPathComponent().appendingPathComponent("DifferentBrowserData")))
    }
    @Test(arguments: ["lease", "browserReuse", "ownerReuse", "browserUID", "ownerUID", "browserUnknown", "ownerUnknown", "argv", "inventoryUnknown"])
    func changedOrUnknownAuthorityNeverRequestsQuit(_ control: String) throws {
        let saved = snapshot(); var calls = 0
        let changed = BrowserProcessLock(pid: saved.lease.pid, executablePath: saved.lease.executablePath,
            browserDataPath: saved.lease.browserDataPath, createdAt: Date(timeIntervalSince1970: 2),
            schemaVersion: 3, ownerToken: saved.lease.ownerToken, phase: .running, relay: saved.lease.relay)
        #expect(throws: ProxyRelayQualificationQuit.Failure.changedAuthority) {
            try ProxyRelayQualificationQuit.request(expected: saved, currentUserID: uid,
                readLease: { control == "lease" ? changed : saved.lease },
                inspectBrowser: { control == "browserUnknown" ? nil : identity(control == "browserReuse" ? 101 : 100, uid: control == "browserUID" ? 124 : 123) },
                inspectOwner: { control == "ownerUnknown" ? nil : identity(control == "ownerReuse" ? 201 : 200, uid: control == "ownerUID" ? 124 : 123) },
                inspectExactProcess: { control == "argv" ? .unrelated : control == "inventoryUnknown" ? .unknown : .expected },
                nativeQuit: { calls += 1; return true })
        }
        #expect(calls == 0)
    }
    @Test(arguments: ["lease", "browser", "owner"])
    func lastMomentChangeNeverRequestsQuit(_ control: String) throws {
        let saved = snapshot(); var leaseReads = 0, browserReads = 0, ownerReads = 0, calls = 0
        #expect(throws: ProxyRelayQualificationQuit.Failure.changedAuthority) {
            try ProxyRelayQualificationQuit.request(expected: saved, currentUserID: uid,
                readLease: {
                    leaseReads += 1
                    if control == "lease" && leaseReads == 2 { throw ProxyRelayQualificationQuit.Failure.changedAuthority }
                    return saved.lease
                },
                inspectBrowser: { browserReads += 1; return control == "browser" && browserReads == 2 ? identity(101) : identity(100) },
                inspectOwner: { ownerReads += 1; return control == "owner" && ownerReads == 2 ? nil : identity(200) },
                inspectExactProcess: { .expected }, nativeQuit: { calls += 1; return true })
        }
        #expect(calls == 0)
    }
    @Test func refusedQuitHasNoRetryOrForceFallback() throws {
        let saved = snapshot(); var calls = 0
        #expect(throws: ProxyRelayQualificationQuit.Failure.quitRefused) {
            try ProxyRelayQualificationQuit.request(expected: saved, currentUserID: uid,
                readLease: { saved.lease }, inspectBrowser: { identity(100) }, inspectOwner: { identity(200) },
                inspectExactProcess: { .expected }, nativeQuit: { calls += 1; return false })
        }
        #expect(calls == 1)
    }
    @Test func additionalDataDirectoryCannotAuthorizeQualificationQuit() {
        let pid = getpid(), executable = "/private/tmp/owned/Browser", data = "/private/tmp/owned/data"
        let lease = BrowserProcessLock(pid: pid, executablePath: executable, browserDataPath: data, createdAt: Date())
        for extra in [[], ["--user-data-dir=/private/tmp/other/data"], ["--user-data-dir", "/private/tmp/other"],
                      ["--user-data-dir="], ["--user-data-dir=relative"]] {
            let arguments = [executable, "--user-data-dir=" + data] + extra
            let inventory = BrowserProcessInventory(processes: [pid: .init(executablePath: executable, arguments: arguments)])
            #expect(inventory.inspectExactQualificationProcess(lease) == (extra.isEmpty ? .expected : .unrelated))
        }
    }
    @Test func reparentingDoesNotChangeThePinnedGeneration() throws {
        let saved = snapshot(); var calls = 0
        func reparented(_ seconds: Int64) -> ProxyRelayOwnerProcessIdentity {
            .init(generation: .init(startSeconds: seconds, startMicroseconds: 456), userID: uid, parentProcessID: 1)
        }
        try ProxyRelayQualificationQuit.request(expected: saved, currentUserID: uid,
            readLease: { saved.lease }, inspectBrowser: { reparented(100) }, inspectOwner: { reparented(200) },
            inspectExactProcess: { .expected }, nativeQuit: { calls += 1; return true })
        #expect(calls == 1)
    }
}
#endif
