import Darwin
import Foundation
import Testing
@testable import DirectUpdateCore
@testable import NeAntik

@Suite(.serialized) @MainActor struct ReleaseAuditBrowserIsolationTests {
    // These tests launch only owned shell stubs. Resource state is an explicit
    // fixture input; live pressure must not hide the custody failure under test.
    private func fixtureAdmission() -> ManagerLaunchAdmission {
        ManagerLaunchAdmission(observePressure: false, thermalState: { .nominal })
    }
    private func fixture() throws -> (URL, AppPaths, ReleaseAuditBrowserIsolation) {
        let parent = URL(fileURLWithPath: "/private/tmp/neantik-update-audit-" + UUID().uuidString.lowercased())
        let root = parent.appendingPathComponent("manager-data")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let transfer = try DirectUpdateAuditIsolation.capture(root: root, validatedManifest: Data("synthetic-manifest".utf8))
        try transfer.validate()
        let isolation = try ReleaseAuditBrowserIsolation.authenticatedContinuation(transfer)
        return (parent, AppPaths(rootDirectory: root), isolation)
    }
    private func addACL(_ url: URL) throws {
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "user:" + NSUserName() + " allow read", url.path]
        command.standardOutput = FileHandle.nullDevice; command.standardError = FileHandle.nullDevice
        try command.run(); command.waitUntilExit()
        try #require(command.terminationStatus == 0)
    }
    @Test func matchingRootGrantsNativeMockStorageAndOwnedReservationsOnly() throws {
        let (parent, paths, isolation) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let data = paths.browserDataDirectory(for: UUID())
        #expect(try isolation.arguments(paths: paths, browserDataDirectory: data) == ["--use-mock-keychain"])
        #expect(!String(reflecting: isolation).contains(parent.path))
        #expect(throws: (any Error).self) { try isolation.validateBeforeExec(paths: paths, browserDataDirectory: data) }
        try paths.prepareBaseDirectories()
        try paths.prepareProfileDirectories(for: UUID(uuidString: data.deletingLastPathComponent().lastPathComponent)!)
        try isolation.validateBeforeExec(paths: paths, browserDataDirectory: data)
        let manager = BrowserProcessManager(launchAdmission: fixtureAdmission(), paths: paths, processIdentityValidator: { _ in false },
            releaseAuditBrowserIsolation: isolation, browserDataProcessInspector: { _ in .absent })
        defer { manager.suspendPassiveObservations() }
        let reservation = try manager.reserveFingerprintAuditLaunch(startURL: URL(string: "http://127.0.0.1:8000/fixture")!, httpLoopbackPort: 8000)
        #expect(reservation.dataDirectory.deletingLastPathComponent() == paths.rootDirectory.appendingPathComponent("FingerprintAuditSessions", isDirectory: true))
        try isolation.validateBeforeExec(paths: paths, browserDataDirectory: reservation.dataDirectory)
    }
    @Test(arguments: ["other-root", "prefix", "root-itself", "outside", "nested-symlink", "child-mode", "child-acl", "child-flags"])
    func dataPathsCannotEscapeOrBecomePermissive(kind: String) throws {
        let (parent, paths, isolation) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let id = UUID(); try paths.prepareBaseDirectories(); try paths.prepareProfileDirectories(for: id)
        var data = paths.browserDataDirectory(for: id), selectedPaths = paths
        defer { _ = chflags(paths.profileDirectory(for: id).path, 0) }
        switch kind {
        case "other-root": selectedPaths = AppPaths(rootDirectory: parent)
        case "prefix": data = URL(fileURLWithPath: paths.rootDirectory.path + "-other/BrowserData")
        case "root-itself": data = paths.rootDirectory
        case "outside": data = parent.appendingPathComponent("BrowserData")
        case "nested-symlink":
            let saved = paths.profileDirectory(for: id).appendingPathExtension("saved")
            try FileManager.default.moveItem(at: paths.profileDirectory(for: id), to: saved)
            try FileManager.default.createSymbolicLink(at: paths.profileDirectory(for: id), withDestinationURL: saved)
        case "child-mode": #expect(chmod(paths.profileDirectory(for: id).path, 0o755) == 0)
        case "child-acl": try addACL(paths.profileDirectory(for: id))
        default: #expect(chflags(paths.profileDirectory(for: id).path, UInt32(UF_HIDDEN)) == 0)
        }
        #expect(throws: (any Error).self) { try isolation.validateBeforeExec(paths: selectedPaths, browserDataDirectory: data) }
    }
    @Test(arguments: ["root", "parent", "root-mode", "parent-mode"])
    func retainedRootAndParentRejectReplacement(kind: String) throws {
        let (parent, paths, isolation) = try fixture(), moved = parent.appendingPathExtension("saved")
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: moved) }
        switch kind {
        case "root":
            try FileManager.default.moveItem(at: paths.rootDirectory, to: parent.appendingPathComponent("saved-root"))
            try FileManager.default.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        case "parent":
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createDirectory(at: paths.rootDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        case "root-mode": #expect(chmod(paths.rootDirectory.path, 0o755) == 0)
        default: #expect(chmod(parent.path, 0o755) == 0)
        }
        #expect(throws: (any Error).self) { try isolation.validate() }
    }
    @Test(arguments: ["intermediate", "leaf"])
    func retainedChildCustodyRejectsPathReplacementAfterOpen(kind: String) throws {
        let (parent, paths, isolation) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let id = UUID(); try paths.prepareBaseDirectories(); try paths.prepareProfileDirectories(for: id)
        let custody = try isolation.validateBeforeExec(paths: paths, browserDataDirectory: paths.browserDataDirectory(for: id))
        let changed = kind == "leaf" ? paths.browserDataDirectory(for: id) : paths.profileDirectory(for: id)
        try FileManager.default.moveItem(at: changed, to: changed.appendingPathExtension("saved"))
        try FileManager.default.createDirectory(at: paths.browserDataDirectory(for: id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try isolation.validate() // unchanged root alone cannot catch this
        #expect(throws: (any Error).self) { try custody.validate() }
    }
    @Test(arguments: ["ordinary", "bound-normal", "bound-fingerprint"])
    func actualLaunchAddsMockFlagOnlyWithCapability(kind: String) async throws {
        let audit = kind != "ordinary"
        let (parent, paths, isolation) = try fixture()
        var safeToRemoveFixture = true
        defer { if safeToRemoveFixture { try? FileManager.default.removeItem(at: parent) } }
        try paths.prepareBaseDirectories()
        let fake = parent.appendingPathComponent("owned-browser")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args.tmp\"\n/bin/mv \"$0.args.tmp\" \"$0.args\"\nsleep 0.15\n".utf8).write(to: fake)
        #expect(chmod(fake.path, 0o700) == 0)
        let manager = BrowserProcessManager(launchAdmission: fixtureAdmission(), paths: paths, processIdentityValidator: { _ in false },
            releaseAuditBrowserIsolation: audit ? isolation : nil, browserDataProcessInspector: { _ in .absent })
        defer { manager.suspendPassiveObservations() }
        let profile = BrowserProfile(name: "Synthetic storage isolation")
        let runtime = BrowserRuntime(name: "Synthetic", executableURL: fake, source: "Fixture")
        safeToRemoveFixture = false // Retain the owned fixture if process shutdown cannot be established.
        if kind == "bound-fingerprint" {
            let url = URL(string: "http://127.0.0.1:8000/fixture")!
            let reservation = try manager.reserveFingerprintAuditLaunch(startURL: url, httpLoopbackPort: 8000)
            let custody = try manager.retainFingerprintAuditDirectory(reservation)
            try manager.launch(profile: profile, runtime: runtime, startURLOverride: url,
                browserDataDirectoryOverride: reservation.dataDirectory, fingerprintAuditReservation: reservation,
                purpose: .fingerprintAudit(httpLoopbackPort: 8000))
            manager.releaseFingerprintAuditReservation(reservation)
            manager.releaseFingerprintAuditReservation(reservation)
            try custody.validate()
            #expect(throws: (any Error).self) { try manager.retainFingerprintAuditDirectory(reservation) }
        } else { try manager.launch(profile: profile, runtime: runtime) }
        let capture = fake.appendingPathExtension("args")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: capture.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let args = try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args.contains("--use-mock-keychain") == audit)
        #expect(args.filter { $0 == "--use-mock-keychain" }.count == (audit ? 1 : 0))
        if kind == "bound-fingerprint" {
            #expect(args.contains { $0.hasPrefix("--user-data-dir=" + paths.rootDirectory.path + "/FingerprintAuditSessions/") })
        } else { #expect(args.contains("--user-data-dir=" + paths.browserDataDirectory(for: profile.id).path)) }
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            manager.reconcile(profiles: [profile])
            if manager.processState(for: profile.id) == .stopped && !manager.runningProfileIDs.contains(profile.id) {
                safeToRemoveFixture = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        #expect(safeToRemoveFixture, "Owned fixture process did not reach stopped state before the deadline")
    }
    @Test func pressureRefusesOwnedExecutableBeforeCreatingLease() throws {
        let (parent, paths, isolation) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let profile = BrowserProfile(name: "Synthetic pressure refusal")
        let fake = parent.appendingPathComponent("never-pressure-browser")
        try paths.prepareBaseDirectories(); try paths.prepareProfileDirectories(for: profile.id)
        try Data("#!/bin/sh\n/usr/bin/touch \"$0.started\"\n".utf8).write(to: fake)
        #expect(chmod(fake.path, 0o700) == 0)
        let admission = fixtureAdmission()
        admission.setPressureForTesting(true)
        let manager = BrowserProcessManager(launchAdmission: admission, paths: paths,
            processIdentityValidator: { _ in false }, releaseAuditBrowserIsolation: isolation,
            browserDataProcessInspector: { _ in .absent })
        defer { manager.suspendPassiveObservations() }
        #expect(throws: ManagerLaunchAdmissionError.pressure) {
            try manager.launch(profile: profile,
                runtime: BrowserRuntime(name: "Synthetic", executableURL: fake, source: "Fixture"))
        }
        #expect(!FileManager.default.fileExists(atPath: fake.appendingPathExtension("started").path))
        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(try paths.privateFileEntryKind(paths.lockFile(for: profile.id)) == .missing)
    }
    @Test func finalPreExecRefusalRemovesProvisionalLeaseAndNeverRunsExecutable() throws {
        let (parent, paths, isolation) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let profile = BrowserProfile(name: "Synthetic refusal"), fake = parent.appendingPathComponent("never-browser")
        try paths.prepareBaseDirectories(); try paths.prepareProfileDirectories(for: profile.id)
        try Data("#!/bin/sh\n/usr/bin/touch \"$0.started\"\n".utf8).write(to: fake); #expect(chmod(fake.path, 0o700) == 0)
        try addACL(paths.browserDataDirectory(for: profile.id))
        let manager = BrowserProcessManager(launchAdmission: fixtureAdmission(), paths: paths, processIdentityValidator: { _ in false },
            releaseAuditBrowserIsolation: isolation, browserDataProcessInspector: { _ in .absent })
        defer { manager.suspendPassiveObservations() }
        #expect(throws: NeAntikError.self) { try manager.launch(profile: profile,
            runtime: BrowserRuntime(name: "Synthetic", executableURL: fake, source: "Fixture")) }
        #expect(!FileManager.default.fileExists(atPath: fake.appendingPathExtension("started").path))
        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(try paths.privateFileEntryKind(paths.lockFile(for: profile.id)) == .missing)
    }
    @Test(arguments: ["symlink", "directory"]) func ordinaryReservationCannotFollowReplacedDirectoryAlias(kind: String) throws {
        let (parent, paths, _) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let manager = BrowserProcessManager(launchAdmission: fixtureAdmission(), paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent })
        let profile = BrowserProfile(name: "Synthetic reservation refusal"), url = URL(string: "http://127.0.0.1:8000/fixture")!
        let reservation = try manager.reserveFingerprintAuditLaunch(startURL: url, httpLoopbackPort: 8000)
        let custody = try manager.retainFingerprintAuditDirectory(reservation)
        let saved = reservation.dataDirectory.appendingPathExtension("saved"), replacement = parent.appendingPathComponent("other-test-data")
        defer {
            manager.stop(profileID: profile.id); manager.suspendPassiveObservations()
            try? FileManager.default.removeItem(at: reservation.dataDirectory); try? FileManager.default.removeItem(at: saved)
        }
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: reservation.dataDirectory, to: saved)
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: reservation.dataDirectory, withDestinationURL: replacement)
        } else {
            try FileManager.default.createDirectory(at: reservation.dataDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let sentinel = reservation.dataDirectory.appendingPathComponent("sentinel")
        try Data("must survive".utf8).write(to: sentinel)
        do {
            try manager.launch(profile: profile, runtime: BrowserRuntime(name: "Never launched", executableURL: URL(fileURLWithPath: "/usr/bin/true"), source: "Fixture"),
                startURLOverride: url, browserDataDirectoryOverride: reservation.dataDirectory,
                fingerprintAuditReservation: reservation, purpose: .fingerprintAudit(httpLoopbackPort: 8000))
            Issue.record("Replaced ordinary reservation was admitted")
        } catch {
            guard let error = error as? NeAntikError, case .fingerprintAuditFailed = error else {
                Issue.record("Ordinary reservation did not refuse before launch preparation"); return
            }
        }
        #expect(!manager.runningProfileIDs.contains(profile.id))
        #expect(try paths.privateFileEntryKind(paths.lockFile(for: profile.id)) == .missing)
        #expect(throws: (any Error).self) { try custody.discard() }
        #expect(try Data(contentsOf: sentinel) == Data("must survive".utf8))
        manager.releaseFingerprintAuditReservation(reservation)
        manager.releaseFingerprintAuditReservation(reservation)
        #expect(throws: (any Error).self) { try manager.retainFingerprintAuditDirectory(reservation) }
    }
    @Test func releasingUnusedReservationKeepsCleanupCustodyAndIsIdempotent() throws {
        let (parent, paths, isolation) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let manager = BrowserProcessManager(launchAdmission: fixtureAdmission(), paths: paths, processIdentityValidator: { _ in false },
            releaseAuditBrowserIsolation: isolation, browserDataProcessInspector: { _ in .absent })
        defer { manager.suspendPassiveObservations() }
        let reservation = try manager.reserveFingerprintAuditLaunch(startURL: URL(string: "http://127.0.0.1:8000/fixture")!, httpLoopbackPort: 8000)
        let custody = try manager.retainFingerprintAuditDirectory(reservation)
        let nested = reservation.dataDirectory.appendingPathComponent("Default")
        #expect(manager.hasWorkPreventingUpdate)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("synthetic".utf8).write(to: nested.appendingPathComponent("fixture"))
        manager.releaseFingerprintAuditReservation(reservation)
        manager.releaseFingerprintAuditReservation(reservation)
        #expect(!manager.hasWorkPreventingUpdate)
        #expect(throws: (any Error).self) { try manager.retainFingerprintAuditDirectory(reservation) }
        try custody.discard()
        #expect(!FileManager.default.fileExists(atPath: reservation.dataDirectory.path))
    }
    @Test func unsafeNestedSymlinkRetainsTreeAndExternalSentinel() throws {
        let (parent, paths, isolation) = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let manager = BrowserProcessManager(launchAdmission: fixtureAdmission(), paths: paths, processIdentityValidator: { _ in false },
            releaseAuditBrowserIsolation: isolation, browserDataProcessInspector: { _ in .absent })
        defer { manager.suspendPassiveObservations() }
        let reservation = try manager.reserveFingerprintAuditLaunch(startURL: URL(string: "http://127.0.0.1:8000/fixture")!, httpLoopbackPort: 8000)
        defer { manager.releaseFingerprintAuditReservation(reservation) }
        let custody = try manager.retainFingerprintAuditDirectory(reservation)
        let external = parent.appendingPathComponent("external-sentinel")
        try Data("must survive".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: reservation.dataDirectory.appendingPathComponent("link"), withDestinationURL: external)
        #expect(throws: (any Error).self) { try custody.discard() }
        #expect(try Data(contentsOf: external) == Data("must survive".utf8))
        #expect(FileManager.default.fileExists(atPath: reservation.dataDirectory.path))
    }
}
