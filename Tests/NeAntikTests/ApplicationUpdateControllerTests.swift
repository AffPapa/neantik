import Darwin
import Foundation
import Testing
@testable import DirectUpdateCore
@testable import NeAntik

@MainActor
@Suite(.serialized)
struct ApplicationUpdateControllerTests {
    @Test func disabledChannelNeverAcquiresInstallAuthority() throws {
        let gate = ApplicationUpdateAdmission()
        let activity = try gate.beginActivity()
        let controller = ApplicationUpdateController(channelEnabled: false, admission: gate)
        controller.present(workspaceIsBusy: true)
        #expect(controller.isPresented && !controller.holdsFence && controller.canClose)
        controller.beginInspection(archive: URL(fileURLWithPath: "/not-used"), manifest: URL(fileURLWithPath: "/not-used"))
        #expect(controller.phase == .idle)
        controller.close(); gate.finishActivity(activity)
        #expect(!controller.isPresented)
    }
    @Test func activeWorkerAndWorkspaceRefuseFenceAndDuplicatePresentation() throws {
        let gate = ApplicationUpdateAdmission()
        let controller = ApplicationUpdateController(channelEnabled: true, admission: gate)
        controller.present(workspaceIsBusy: true)
        #expect(!controller.holdsFence && controller.message != nil)
        controller.close()
        let activity = try gate.beginActivity()
        controller.present(workspaceIsBusy: false)
        #expect(!controller.holdsFence)
        controller.close(); gate.finishActivity(activity)
        controller.present(workspaceIsBusy: false)
        #expect(controller.holdsFence)
        controller.present(workspaceIsBusy: false)
        controller.close()
        #expect(!gate.isUpdating)
    }
    @Test func cancellationKeepsFenceUntilOwnerDrainAndClose() async throws {
        let gate = ApplicationUpdateAdmission(), transport = UpdateUITransportFixture()
        let manifest = try manifestFixture(); defer { try? FileManager.default.removeItem(at: manifest) }
        let controller = ApplicationUpdateController(channelEnabled: true, admission: gate, makeClient: { transport })
        controller.present(workspaceIsBusy: false)
        controller.beginInspection(archive: manifest, manifest: manifest)
        for _ in 0..<2_000 { if await transport.inspectCount > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        controller.cancel(); controller.close()
        #expect(controller.phase == .cancelling && gate.isUpdating)
        #expect(throws: ApplicationUpdateAdmissionError.self) { try gate.beginActivity() }
        await transport.releaseInspection()
        for _ in 0..<2_000 { if await transport.drainCount > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(gate.isUpdating && controller.phase == .cancelling)
        await transport.releaseDrain()
        for _ in 0..<2_000 { if controller.phase == .idle { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(controller.phase == .idle && gate.isUpdating)
        #expect(await transport.inspectCount == 1)
        #expect(await transport.commitCount == 0)
        controller.close(); #expect(!gate.isUpdating)
    }
    @Test func cancelledInspectionCleanupFailureRemainsTerminalAfterSuccessfulDrain() async throws {
        let gate = ApplicationUpdateAdmission(), transport = UpdateUITransportFixture(cleanupFailure: true)
        let manifest = try manifestFixture(); defer { try? FileManager.default.removeItem(at: manifest) }
        let controller = ApplicationUpdateController(channelEnabled: true, admission: gate, makeClient: { transport })
        controller.present(workspaceIsBusy: false)
        controller.beginInspection(archive: manifest, manifest: manifest)
        for _ in 0..<2_000 { if await transport.inspectCount > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        controller.cancel(); await transport.releaseInspection()
        for _ in 0..<2_000 { if await transport.drainCount > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        await transport.releaseDrain()
        for _ in 0..<2_000 { if controller.phase == .restartRequired { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(controller.phase == .restartRequired && gate.isUpdating)
        controller.close()
        #expect(controller.isPresented && gate.isUpdating)
        #expect(throws: ApplicationUpdateAdmissionError.self) { try gate.beginActivity() }
    }
    @Test func automaticFailureDrainDisablesCancelAndRetryUntilItsCompletion() async throws {
        let gate = ApplicationUpdateAdmission(), transport = UpdateUITransportFixture()
        let manifest = try manifestFixture(); defer { try? FileManager.default.removeItem(at: manifest) }
        let controller = ApplicationUpdateController(channelEnabled: true, admission: gate, makeClient: { transport })
        controller.present(workspaceIsBusy: false)
        controller.beginInspection(archive: manifest, manifest: manifest)
        for _ in 0..<2_000 { if await transport.inspectCount > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        await transport.releaseInspection()
        for _ in 0..<2_000 { if await transport.drainCount > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(controller.phase == .cancelling && !controller.canCancel)
        controller.cancel(); controller.beginInspection(archive: manifest, manifest: manifest)
        #expect(await transport.inspectCount == 1)
        await transport.releaseDrain()
        for _ in 0..<2_000 { if controller.phase == .idle { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await transport.drainCount == 1)
        #expect(controller.phase == .idle && controller.message != nil)
        controller.close(); #expect(!gate.isUpdating)
    }
    @Test func explicitCommitCannotBeCancelledAndTerminatesOnlyAfterHandoff() async throws {
        let gate = ApplicationUpdateAdmission(), transport = UpdateUITransportFixture(offerSuccess: true)
        let manifest = try manifestFixture(); defer { try? FileManager.default.removeItem(at: manifest) }
        var quits = 0
        let controller = ApplicationUpdateController(channelEnabled: true, admission: gate,
            makeClient: { transport }, terminate: { quits += 1 })
        controller.present(workspaceIsBusy: false)
        controller.beginInspection(archive: manifest, manifest: manifest)
        // Duplicate click is refused even before the asynchronous call begins.
        controller.beginInspection(archive: manifest, manifest: manifest)
        for _ in 0..<2_000 { if await transport.inspectCount > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        await transport.releaseInspection()
        for _ in 0..<2_000 { if controller.phase == .offered { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(controller.phase == .offered && controller.offeredVersion == "1.0.0 (999)")
        #expect(await transport.inspectCount == 1)
        controller.installAndRestart(); controller.installAndRestart()
        controller.cancel(); controller.close()
        for _ in 0..<2_000 { if await transport.commitCount > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(controller.phase == .committing && gate.isUpdating && quits == 0)
        #expect(await transport.commitCount == 1)
        #expect(await transport.drainCount == 0)
        await transport.releaseCommit()
        for _ in 0..<2_000 { if quits > 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(quits == 1 && gate.isUpdating)
        // State fixture does not claim a real signed filesystem installation.
    }
    @Test func manifestReaderRefusesSymlinkFIFOAndOversizedInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-update-ui-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: file)
        #expect(try ApplicationUpdateController.readManifest(file) == Data("{}".utf8))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try ApplicationUpdateController.readManifest(link) }
        let fifo = root.appendingPathComponent("fifo.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try ApplicationUpdateController.readManifest(fifo) }
        try Data(count: 128 * 1024 + 1).write(to: file)
        #expect(throws: (any Error).self) { try ApplicationUpdateController.readManifest(file) }
    }
    private func manifestFixture() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-update-ui-" + UUID().uuidString + ".json")
        try Data("{}".utf8).write(to: file); return file
    }
}
private actor UpdateUITransportFixture: ApplicationUpdateTransport {
    private(set) var inspectCount = 0, drainCount = 0, commitCount = 0
    private let cleanupFailure: Bool, offerSuccess: Bool
    init(cleanupFailure: Bool = false, offerSuccess: Bool = false) { self.cleanupFailure = cleanupFailure; self.offerSuccess = offerSuccess }
    private var inspecting: CheckedContinuation<Void, Never>?, draining: CheckedContinuation<Void, Never>?, committing: CheckedContinuation<Void, Never>?
    func inspect(archive: URL, manifest: Data) async throws -> DirectUpdateOwnerOffer {
        inspectCount += 1
        await withCheckedContinuation { inspecting = $0 }
        if offerSuccess {
            let request = try DirectUpdateOwnerInit(archive: archive, manifest: manifest)
            return try DirectUpdateOwnerOffer(request: request, version: "1.0.0", build: 999,
                archiveSHA256: Data(count: 32), runtimeSHA256: Data(count: 32), candidateCDHash: Data(count: 20))
        }
        if cleanupFailure { throw DirectUpdateOwnerClientError.cleanup }
        throw CancellationError()
    }
    func cancelAndDrain() async throws {
        drainCount += 1
        await withCheckedContinuation { draining = $0 }
    }
    func consentAndHandoff() async throws { commitCount += 1; await withCheckedContinuation { committing = $0 } }
    func releaseInspection() { inspecting?.resume(); inspecting = nil }
    func releaseCommit() { committing?.resume(); committing = nil }
    func releaseDrain() { draining?.resume(); draining = nil }
}
