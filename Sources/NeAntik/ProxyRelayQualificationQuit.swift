#if DEBUG
import Darwin
import Foundation

/// Private QA authority, captured at launch and returned only over the owned
/// pipe. A PID or shared runtime bundle ID alone never authorizes a quit.
enum ProxyRelayQualificationQuit {
    enum Failure: Error { case changedAuthority, quitRefused }
    struct Generation: Codable, Equatable {
        let seconds: Int64
        let microseconds: Int32
        let userID: uid_t
        init(_ identity: ProxyRelayOwnerProcessIdentity) {
            seconds = identity.generation.startSeconds
            microseconds = identity.generation.startMicroseconds
            userID = identity.userID
        }
        func matches(_ identity: ProxyRelayOwnerProcessIdentity?) -> Bool {
            identity.map { Generation($0) == self } == true
        }
    }
    struct Snapshot: Codable, Equatable {
        let lease: BrowserProcessLock
        let browser: Generation
        let owner: Generation
    }

    static func matchesDataPath(_ lease: BrowserProcessLock, expected: URL) -> Bool {
        URL(fileURLWithPath: lease.browserDataPath).standardizedFileURL.path == expected.standardizedFileURL.path
    }

    /// Injected reads make PID reuse, unknown inspection and last-moment lease
    /// changes testable without signalling any process. The native operation
    /// must additionally check NSRunningApplication's executable and readiness.
    static func request(
        expected: Snapshot, currentUserID: uid_t,
        readLease: () throws -> BrowserProcessLock,
        inspectBrowser: () -> ProxyRelayOwnerProcessIdentity?,
        inspectOwner: () -> ProxyRelayOwnerProcessIdentity?,
        inspectExactProcess: () -> BrowserProcessIdentityInspection,
        nativeQuit: () -> Bool
    ) throws {
        guard let relay = expected.lease.relay, expected.lease.phase == .running,
              expected.lease.pid > 1, relay.ownerPID > 1,
              expected.lease.ownerToken == relay.sessionGeneration,
              expected.browser.seconds > 0, (0..<1_000_000).contains(expected.browser.microseconds),
              expected.browser.userID == currentUserID,
              expected.owner.userID == currentUserID, relay.ownerUID == currentUserID,
              expected.owner.seconds == relay.ownerStartSeconds,
              expected.owner.microseconds == relay.ownerStartMicroseconds,
              try readLease() == expected.lease,
              inspectExactProcess() == .expected,
              expected.browser.matches(inspectBrowser()), expected.owner.matches(inspectOwner())
        else { throw Failure.changedAuthority }
        try relay.validate(ownerToken: expected.lease.ownerToken)
        // Repeat immediately before requesting native quit. No SIGTERM/KILL or
        // bundle-name fallback, and no lease removal on refusal or uncertainty.
        guard try readLease() == expected.lease,
              expected.owner.matches(inspectOwner()), expected.browser.matches(inspectBrowser())
        else { throw Failure.changedAuthority }
        guard nativeQuit() else { throw Failure.quitRefused }
    }
}
#endif
