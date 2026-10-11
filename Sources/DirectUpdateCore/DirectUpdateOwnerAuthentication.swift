import Darwin
import Foundation

/// Mutual trust is anchored in the actual parent manager and installed signed
/// policy. This cannot be constructed from a request, PID or unsigned plist.
final package class DirectUpdateOwnerAuthentication: @unchecked Sendable, CustomReflectable {
    package let policy: DirectUpdateInstalledPolicy, workspace: DirectUpdateOwnerWorkspace
    package let installation: URL
    private let parentPID: pid_t, parentIdentity: ProxyRelayOwnerProcessIdentity
    private let parentCode: ProxyRelayExpectedCode, selfIdentity: ProxyRelayOwnerProcessIdentity
    package var customMirror: Mirror { Mirror(self, children: [:]) }
    private init(policy: DirectUpdateInstalledPolicy, workspace: DirectUpdateOwnerWorkspace, installation: URL,
                 parentPID: pid_t, parentIdentity: ProxyRelayOwnerProcessIdentity,
                 parentCode: ProxyRelayExpectedCode, selfIdentity: ProxyRelayOwnerProcessIdentity) {
        self.policy = policy; self.workspace = workspace; self.installation = installation
        self.parentPID = parentPID; self.parentIdentity = parentIdentity; self.parentCode = parentCode; self.selfIdentity = selfIdentity
    }
    package static func authenticate() throws -> Self {
        guard let selfIdentity = DirectProcessIdentityInspector.processIdentity(getpid()), selfIdentity.userID == geteuid(),
              selfIdentity.parentProcessID > 1,
              let parent = DirectProcessIdentityInspector.processIdentity(selfIdentity.parentProcessID), parent.userID == geteuid(),
              let parentPath = DirectUpdateProcessInventory.path(selfIdentity.parentProcessID),
              let ownPath = DirectUpdateProcessInventory.path(getpid()) else { throw DirectUpdateInstallSessionError.identity }
        let installation = try installedApp(executable: URL(fileURLWithPath: parentPath))
        let policy = try DirectUpdateInstalledPolicy.inspect(installedApp: installation)
        let parentCode = try ProxyRelayExpectedCode.qualifiedPin(at: installation,
            expectedIdentifier: DirectUpdateCodeRole.manager.identifier, expectedTeamIdentifier: DirectUpdateCodeSignature.team,
            expectedCDHash: policy.managerCDHash)
        let workspace = try DirectUpdateOwnerWorkspace.inspect(ownerExecutable: URL(fileURLWithPath: ownPath), policy: policy)
        let result = Self(policy: policy, workspace: workspace, installation: installation,
            parentPID: selfIdentity.parentProcessID, parentIdentity: parent, parentCode: parentCode, selfIdentity: selfIdentity)
        try result.validate(requireParent: true); return result
    }
    // Pure syntax only. Production additionally checks BackupFS nofollow path,
    // genuine signature, fixed certificate and the exact kernel live parent.
    static func installedApp(executable: URL) throws -> URL {
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard executable.isFileURL, app.lastPathComponent == "NeAntik.app",
              app.appendingPathComponent("Contents/MacOS/NeAntik") == executable else { throw DirectUpdateInstallSessionError.identity }
        return app
    }
    package func validate(requireParent: Bool) throws {
        try policy.validate(); try workspace.validate()
        guard let currentSelf = DirectProcessIdentityInspector.processIdentity(getpid()),
              currentSelf.generation == selfIdentity.generation, currentSelf.userID == selfIdentity.userID,
              ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: currentSelf,
                expectedCode: workspace.owner.expectedCode) else { throw DirectUpdateInstallSessionError.identity }
        if requireParent {
            guard DirectUpdateProcessInventory.path(parentPID) == installation.appendingPathComponent("Contents/MacOS/NeAntik").path,
                  ProxyRelayLiveCodeVerifier.matches(processID: parentPID, expectedProcess: parentIdentity,
                    expectedCode: parentCode) else { throw DirectUpdateInstallSessionError.identity }
        }
        try policy.validate(); try workspace.validate()
    }
    /// EOF is never this proof. No signal is sent. A reused PID, live manager
    /// or unreadable generation refuses. The driver subsequently requires a
    /// fresh global inventory and participant fences before any swap.
    package func waitForManagerExit(timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let current = DirectProcessIdentityInspector.processIdentity(parentPID) {
                guard current.generation == parentIdentity.generation, current.userID == parentIdentity.userID else {
                    throw DirectUpdateInstallSessionError.identity
                }
            } else if kill(parentPID, 0) == -1, errno == ESRCH {
                try validate(requireParent: false); return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DirectUpdateInstallSessionError.timeout
    }
}
