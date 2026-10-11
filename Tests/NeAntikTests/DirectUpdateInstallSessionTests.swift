import CryptoKit
import Darwin
import DirectInstallFilesystem
import DirectUpdateBootstrapParent
import Foundation
import Testing
@testable import DirectUpdateCore

private final class BootstrapFixtureContext {
    let request: DirectUpdateBootstrapRequest
    var admitted = true, accepted = true, didAdmit = false, didReady = false, cancelAfterAdmission = false, cancelAfterReady = false
    var readyDelayMicroseconds: useconds_t = 0
    var auditRecordDigest: Data?
    init(_ request: DirectUpdateBootstrapRequest) { self.request = request }
}
private func sessionFixtureAdmit(_ pid: pid_t, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    let context = Unmanaged<BootstrapFixtureContext>.fromOpaque(raw!).takeUnretainedValue()
    context.didAdmit = true; return context.admitted ? 1 : 0
}
private func sessionFixtureReady(_ pid: pid_t, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    let context = Unmanaged<BootstrapFixtureContext>.fromOpaque(raw!).takeUnretainedValue()
    guard let bytes else { return 0 }
    do { try context.request.validateReply(Data(bytes: bytes, count: count), auditRecordDigest: context.auditRecordDigest); context.didReady = true
        if context.readyDelayMicroseconds > 0 { usleep(context.readyDelayMicroseconds) }
        return context.accepted ? 1 : 0 }
    catch { return 0 }
}
private func sessionFixtureCancel(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    let context = Unmanaged<BootstrapFixtureContext>.fromOpaque(raw!).takeUnretainedValue()
    return (context.cancelAfterAdmission && context.didAdmit) || (context.cancelAfterReady && context.didReady) ? 1 : 0
}
private final class BootstrapFixtureBundle {}
@Suite(.serialized) struct DirectUpdateInstallSessionTests {
    private func request() throws -> DirectUpdateBootstrapRequest {
        let object: [String: Any] = ["transactionID":UUID().uuidString,"journalSHA256":String(repeating:"a",count:64),
            "candidateReceiptSHA256":String(repeating:"b",count:64),"candidateDevice":42,"candidateInode":43]
        let receipt = try JSONDecoder().decode(InstallFilesystemReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        return try .init(receipt: receipt, cdHash: Data(repeating: 7, count: 20), build: 93,
                         runtimeSHA256: String(repeating:"c",count:64), nonce: Data(repeating: 8, count: 32))
    }
    @Test func strictBindingRoundTrip() throws {
        let request = try request()
        #expect(request.bytes.count == 192)
        #expect(request.candidateDevice == 42 && request.candidateInode == 43 && request.build == 93)
        #expect(try DirectUpdateBootstrapRequest.parse(request.bytes) == request)
        let reply = try request.reply(cdHash: request.candidateCDHash, build: request.build, runtimeSHA256: String(repeating:"c",count:64))
        #expect(reply.count == 128 && request.continuation.count == 36)
        try request.validateReply(reply)
    }
    @Test(arguments: [0, 4, 36, 52, 84, 116, 124, 132, 152, 160, 191])
    func everyRequestBindingIsCoveredByReplyDigest(offset: Int) throws {
        let request = try request(), reply = try request.reply(cdHash: request.candidateCDHash, build: request.build, runtimeSHA256: String(repeating:"c",count:64))
        var altered = request.bytes; altered[offset] ^= 1
        do { let parsed = try DirectUpdateBootstrapRequest.parse(altered); #expect(throws: DirectUpdateInstallSessionError.reply) { try parsed.validateReply(reply) } }
        catch { #expect(error as? DirectUpdateInstallSessionError == .request) }
    }
    @Test(arguments: [0, 4, 36, 68, 88, 96, 127])
    func wrongReplyNonceReceiptCodeBuildRuntimeRefuses(offset: Int) throws {
        let request = try request()
        var reply = try request.reply(cdHash: request.candidateCDHash, build: request.build, runtimeSHA256: String(repeating:"c",count:64)); reply[offset] ^= 1
        #expect(throws: DirectUpdateInstallSessionError.reply) { try request.validateReply(reply) }
        #expect(throws: DirectUpdateInstallSessionError.reply) { try request.validateReply(reply + Data([0])) }
        #expect(throws: DirectUpdateInstallSessionError.reply) { try request.validateReply(reply.dropLast()) }
    }
    private func fixture(_ mode: String) throws -> (URL, URL) {
        var binary: URL?
        for base in [Bundle(for: BootstrapFixtureBundle.self).bundleURL, URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()] {
            var directory = base
            for _ in 0..<6 { let candidate = directory.appendingPathComponent("NeAntikUpdateBootstrapFixture")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { binary = candidate; break }; directory.deleteLastPathComponent() }
        }
        let source = try #require(binary), root = URL(fileURLWithPath: "/private/tmp/neantik-bootstrap-parent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        let helper = root.appendingPathComponent(mode); try FileManager.default.copyItem(at: source, to: helper)
        return (root, helper)
    }
    private func run(_ helper: URL, _ context: BootstrapFixtureContext, deadline: UInt32 = 500) -> NeAntikBootstrapResult {
        helper.path.withCString { path in context.request.bytes.withUnsafeBytes { bytes in
            neantik_update_bootstrap_run(path, bytes.bindMemory(to: UInt8.self).baseAddress!, deadline,
                sessionFixtureAdmit, sessionFixtureReady, sessionFixtureCancel, Unmanaged.passUnretained(context).toOpaque())
        } }
    }
    @Test(arguments: ["ok", "environment", "cancel-after-ready", "descriptor"])
    func actualCompleteReplyContinueAndHandoff(mode: String) throws {
        let (root, helper) = try fixture(mode == "cancel-after-ready" ? "ok":mode); defer { try? FileManager.default.removeItem(at:root) }
        var binding = try request()
        let fd = open("/dev/null", O_RDONLY)
        #expect(fd > 2 && fd < 256); defer { close(fd) }
        if mode == "descriptor" { var bytes = binding.bytes; bytes[4] = UInt8(fd); binding = try .parse(bytes) }
        setenv("NEANTIK_BOOTSTRAP_TEST_SECRET", "synthetic-fixture-only", 1); defer { unsetenv("NEANTIK_BOOTSTRAP_TEST_SECRET") }
        let context = BootstrapFixtureContext(binding); context.cancelAfterReady = mode == "cancel-after-ready"
        let result = run(helper, context)
        #expect(result.status == NUB_COMPLETE && result.handed_off == 1 && result.reaped == 0 && context.didReady)
        var status: Int32 = 0
        #expect(waitpid(result.process_id, &status, 0) == result.process_id && status == 0)
    }
    @Test func legacyActualGuestIsReapedBeforeAuditReadinessOrCommit() throws {
        let (root, helper) = try fixture("ok"); defer { try? FileManager.default.removeItem(at: root) }
        let context = BootstrapFixtureContext(try request())
        context.auditRecordDigest = Data(repeating: 0x31, count: 32)
        let result = run(helper, context)
        #expect(result.status != NUB_COMPLETE && result.handed_off == 0 && result.reaped == 1 && !context.didReady)
        var status: Int32 = 0
        #expect(waitpid(result.process_id, &status, WNOHANG) == -1 && errno == ECHILD)
    }
    @Test(arguments: ["hang", "descendant", "abnormal", "stderr", "flood", "short", "wrong"])
    func brokenActualGuestNeverHandsOff(mode: String) throws {
        let (root, helper) = try fixture(mode); defer { try? FileManager.default.removeItem(at:root) }
        let context = BootstrapFixtureContext(try request()), result = run(helper, context, deadline:150)
        #expect(result.status != NUB_COMPLETE && result.handed_off == 0 && result.reaped == 1 && !context.didReady)
        var status: Int32 = 0
        #expect(waitpid(result.process_id, &status, WNOHANG) == -1 && errno == ECHILD)
    }
    @Test func completedReadyDecisionGetsSeparateContinueBudget() throws {
        let (root, helper) = try fixture("ok"); defer { try? FileManager.default.removeItem(at: root) }
        let context = BootstrapFixtureContext(try request()); context.readyDelayMicroseconds = 600_000
        let result = run(helper, context, deadline: 500)
        #expect(context.didReady && result.status == NUB_COMPLETE && result.handed_off == 1 && result.reaped == 0)
        var status: Int32 = 0
        #expect(waitpid(result.process_id, &status, 0) == result.process_id && status == 0)
    }
    @Test(arguments: ["admission", "cancel", "ready-refusal", "closed-hang"])
    func refusedOrCancelledGuestIsOwnedAndReaped(mode: String) throws {
        let (root, helper) = try fixture(mode == "closed-hang" ? "closed-hang":"ok"); defer { try? FileManager.default.removeItem(at:root) }
        let context = BootstrapFixtureContext(try request())
        context.admitted = mode != "admission"; context.accepted = mode != "ready-refusal" && mode != "closed-hang"; context.cancelAfterAdmission = mode == "cancel"
        let result = run(helper, context)
        #expect(result.status != NUB_COMPLETE && result.handed_off == 0 && result.reaped == 1)
        #expect(result.continued == (mode == "ready-refusal" || mode == "closed-hang" ? 1:0))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_BOOTSTRAP_SIGNED_QA_ROOT"] != nil))
    func actualSameIdentityMetadataPinReplacementRefuses() throws {
        let sourceRoot = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEANTIK_BOOTSTRAP_SIGNED_QA_ROOT"]))
        let original = sourceRoot.appendingPathComponent("Owner"), alternate = sourceRoot.appendingPathComponent("DifferentOwner")
        let first = try DirectUpdateEmptyEntitlementCode.inspect(original, identifier: "app.neantik.update-owner-qa")
        let second = try DirectUpdateEmptyEntitlementCode.inspect(alternate, identifier: "app.neantik.update-owner-qa")
        #expect(first.cdHash != second.cdHash)
        let root = URL(fileURLWithPath: "/private/tmp/neantik-bootstrap-code-binding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root, withIntermediateDirectories:false, attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let target = root.appendingPathComponent("Owner")
        try FileManager.default.copyItem(at:original, to:target)
        #expect(try DirectUpdateEmptyEntitlementCode.inspect(target, identifier: "app.neantik.update-owner-qa").cdHash == first.cdHash)
        #expect(throws: ProxyRelayExpectedCode.Failure.invalidIdentity) {
            try DirectUpdateEmptyEntitlementCode.inspect(target, identifier: "app.neantik.update-owner-qa", beforePin: {
                try FileManager.default.removeItem(at:target)
                try FileManager.default.copyItem(at:alternate, to:target)
            })
        }
        #expect(try DirectUpdateEmptyEntitlementCode.inspect(target, identifier: "app.neantik.update-owner-qa").cdHash == second.cdHash)
    }
}
