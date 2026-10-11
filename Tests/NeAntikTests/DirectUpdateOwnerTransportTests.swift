import Darwin
import DirectUpdateBootstrapParent
import Foundation
import Testing
@testable import DirectUpdateCore

private final class OwnerPipeFixtureBundle {}
private final class OwnerPipeContext {
    let helper: URL
    let expectedCode: ProxyRelayExpectedCode?
    private let lock = NSLock()
    private var cancelled = false
    var admitted = false, admissionAllowed = true, cancelAfterAdmission = false, admissionDelay: useconds_t = 0
    init(helper: URL, expectedCode: ProxyRelayExpectedCode? = nil) { self.helper = helper; self.expectedCode = expectedCode }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
private func ownerPipeAdmit(_ pid: pid_t, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let context = Unmanaged<OwnerPipeContext>.fromOpaque(raw).takeUnretainedValue()
    // The actual guest cannot write its marker before the suspended admission.
    guard !FileManager.default.fileExists(atPath: context.helper.path + ".started"),
          let process = DirectProcessIdentityInspector.processIdentity(pid), process.userID == geteuid(), process.parentProcessID == getpid() else { return 0 }
    if let code = context.expectedCode,
       !ProxyRelayLiveCodeVerifier.matches(processID: pid, expectedProcess: process, expectedCode: code) { return 0 }
    context.admitted = true
    if context.admissionDelay > 0 { usleep(context.admissionDelay) }
    if context.cancelAfterAdmission { context.cancel() }
    return context.admissionAllowed && DirectProcessIdentityInspector.processIdentity(pid) == process ? 1:0
}
private func ownerPipeCancel(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 1 }
    return Unmanaged<OwnerPipeContext>.fromOpaque(raw).takeUnretainedValue().isCancelled ? 1:0
}
private final class OwnerBoundaryCancellation {
    private(set) var checks = 0
    func check() -> Int32 { checks += 1; return checks >= 2 ? 1 : 0 }
}
private func ownerBoundaryCancel(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 1 }
    return Unmanaged<OwnerBoundaryCancellation>.fromOpaque(raw).takeUnretainedValue().check()
}
@Suite(.serialized) struct DirectUpdateOwnerTransportTests {
    private func fixture(_ mode: String, source: URL? = nil) throws -> (URL, URL) {
        var binary = source
        if binary == nil {
            for base in [Bundle(for: OwnerPipeFixtureBundle.self).bundleURL, URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()] {
                var directory = base
                for _ in 0..<6 { let candidate = directory.appendingPathComponent("NeAntikUpdateOwnerFixture")
                    if FileManager.default.isExecutableFile(atPath: candidate.path) { binary = candidate; break }; directory.deleteLastPathComponent() }
            }
        }
        let root = URL(fileURLWithPath: "/private/tmp/neantik-owner-pipe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        let helper = root.appendingPathComponent(mode); try FileManager.default.copyItem(at: try #require(binary), to: helper)
        return (root, helper)
    }
    private func begin(_ context: OwnerPipeContext, timeout: UInt32 = 2000) -> (Int32, OpaquePointer?) {
        var session: OpaquePointer?
        let status = context.helper.path.withCString { neantik_update_owner_begin($0, timeout, ownerPipeAdmit, ownerPipeCancel, Unmanaged.passUnretained(context).toOpaque(), &session) }
        return (status, session)
    }
    private func write(_ bytes: Data, session: OpaquePointer, context: OwnerPipeContext, deadline: UInt64? = nil) -> Int32 {
        bytes.withUnsafeBytes { neantik_update_owner_write_frame(session, $0.bindMemory(to: UInt8.self).baseAddress,
            $0.count, deadline ?? neantik_update_pipe_deadline(1000), ownerPipeCancel, Unmanaged.passUnretained(context).toOpaque()) }
    }
    private func read(_ session: OpaquePointer, _ context: OwnerPipeContext, phase: UInt32 = 2000, body: UInt32 = 1000) -> (Int32, Data) {
        var bytes = Data(count: 128 * 1024), received = 0
        let status = bytes.withUnsafeMutableBytes { neantik_update_owner_read_frame(session,
            $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &received, neantik_update_pipe_deadline(phase), body,
            ownerPipeCancel, Unmanaged.passUnretained(context).toOpaque()) }
        return (status, bytes.prefix(received))
    }
    private func cleanup(_ session: OpaquePointer) {
        let result = neantik_update_owner_abort(session, 1500)
        #expect(result.reaped == 1 && result.status == NUB_COMPLETE)
        #expect(neantik_update_owner_dispose(session) == NUB_COMPLETE)
    }
    @Test(arguments: ["ok", "environment", "descriptor", "maximum", "idle-delay"])
    func actualInteractiveRoundtripAndExplicitHandoff(mode: String) throws {
        let (root, helper) = try fixture(mode == "maximum" ? "ok":mode); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper)
        setenv("NEANTIK_OWNER_TEST_SECRET", "synthetic-fixture-only", 1); defer { unsetenv("NEANTIK_OWNER_TEST_SECRET") }
        let fd = open("/dev/null", O_RDONLY); #expect(fd > 2 && fd < 256); defer { close(fd) }
        let (status, value) = begin(context), session = try #require(value)
        defer { #expect(neantik_update_owner_dispose(session) == NUB_COMPLETE) }
        #expect(status == NUB_COMPLETE && context.admitted)
        let bytes = mode == "maximum" ? Data(repeating: 7, count: 128 * 1024):Data([mode == "descriptor" ? UInt8(fd):7])
        #expect(write(bytes, session: session, context: context) == NUB_COMPLETE)
        let (replyStatus, reply) = read(session, context, body: mode == "idle-delay" ? 50:1000)
        #expect(replyStatus == NUB_COMPLETE && reply == bytes)
        // A live owned session cannot be freed by a generic scope destructor.
        #expect(neantik_update_owner_dispose(session) == NUB_WAIT)
        #expect(write(Data([9]), session: session, context: context) == NUB_COMPLETE)
        let (acceptedStatus, accepted) = read(session, context)
        #expect(acceptedStatus == NUB_COMPLETE && accepted == Data([9]))
        let pid = neantik_update_owner_pid(session)
        context.cancel() // Accepted handoff must not be reversed by task cancellation.
        #expect(neantik_update_owner_handoff(session) == NUB_COMPLETE)
        // Post-handoff cancellation has no signal or wait authority.
        let after = neantik_update_owner_abort(session, 100)
        #expect(after.status == NUB_WAIT && after.reaped == 0 && after.escalated == 0)
        var childStatus: Int32 = 0
        #expect(waitpid(pid, &childStatus, 0) == pid && childStatus == 0)
    }
    @Test(arguments: ["refused", "cancelled", "admission-deadline"])
    func admissionNeverContinuesRefusedCancelledOrTimedOutGuest(mode: String) throws {
        let (root, helper) = try fixture("ok"); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper)
        context.admissionAllowed = mode != "refused"; context.cancelAfterAdmission = mode == "cancelled"
        context.admissionDelay = mode == "admission-deadline" ? 150000:0
        let (status, session) = begin(context, timeout: mode == "admission-deadline" ? 50:1000)
        #expect(status == (mode == "refused" ? NUB_ADMISSION:mode == "cancelled" ? NUB_CANCELLED:NUB_TIMEOUT))
        #expect(session == nil && context.admitted)
        #expect(!FileManager.default.fileExists(atPath: helper.path + ".started"))
    }
    @Test(arguments: ["zero", "oversize", "partial-header", "partial-body", "drip-header", "drip-body", "stderr", "closed", "abnormal"])
    func brokenActualFramesNeverHandoff(mode: String) throws {
        let (root, helper) = try fixture(mode); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper), (status, value) = begin(context)
        #expect(status == NUB_COMPLETE)
        let session = try #require(value); defer { cleanup(session) }
        _ = write(Data([1]), session: session, context: context)
        let (reply, bytes) = read(session, context, phase: 500, body: 60)
        #expect(reply != NUB_COMPLETE && bytes.isEmpty)
        if mode == "zero" || mode == "oversize" { #expect(reply == NUB_FRAME) }
        if mode.hasPrefix("partial-") { #expect(reply == NUB_OUTPUT) }
        if mode.hasPrefix("drip-") { #expect(reply == NUB_TIMEOUT) }
    }
    @Test func cancellationWhileWaitingIsBoundedAndExactChildReaped() throws {
        let (root, helper) = try fixture("hang"); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper), (status, value) = begin(context)
        #expect(status == NUB_COMPLETE); let session = try #require(value); defer { cleanup(session) }
        let cancel = Thread { usleep(50000); context.cancel() }; cancel.start()
        let start = Date(), (reply, _) = read(session, context, phase: 2000)
        #expect(reply == NUB_CANCELLED && Date().timeIntervalSince(start) < 1)
    }
    @Test func cooperativeCancellationPreservesAnAlreadyStartedFrameAndNextBoundary() throws {
        for boundary in [false, true] {
            let (root, helper) = try fixture("boundary-frame"); defer { try? FileManager.default.removeItem(at: root) }
            let context = OwnerPipeContext(helper: helper), (_, value) = begin(context)
            let session = try #require(value); defer { cleanup(session) }
            #expect(write(Data([7]), session: session, context: context) == NUB_COMPLETE)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: helper.path + ".frame-started") { usleep(1000) }
            try #require(FileManager.default.fileExists(atPath: helper.path + ".frame-started"))
            let cancellation = OwnerBoundaryCancellation(), raw = Unmanaged.passUnretained(cancellation).toOpaque()
            var data = Data(count: 1024), received = 0
            let status = data.withUnsafeMutableBytes { bytes in
                if boundary {
                    return neantik_update_owner_read_frame_boundary(session, bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count, &received, neantik_update_pipe_deadline(1000), 500, ownerBoundaryCancel, raw)
                }
                return neantik_update_owner_read_frame(session, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, &received, neantik_update_pipe_deadline(1000), 500, ownerBoundaryCancel, raw)
            }
            if boundary {
                #expect(status == NUB_COMPLETE && data.prefix(received) == Data(repeating: 7, count: 4) && cancellation.checks == 1)
                let next = data.withUnsafeMutableBytes {
                    neantik_update_owner_read_frame_boundary(session, $0.bindMemory(to: UInt8.self).baseAddress,
                        $0.count, &received, neantik_update_pipe_deadline(1000), 500, ownerBoundaryCancel, raw)
                }
                #expect(next == NUB_CANCELLED && received == 0)
            } else {
                // Negative control proves ordinary mid-frame cancellation
                // cannot safely resume parsing on the same stream.
                #expect(status == NUB_CANCELLED && received == 0)
            }
        }
    }
    @Test func abortEscalationIsBoundedAndRepeatedAbortDoesNotSignal() throws {
        let (root, helper) = try fixture("hang-kill"); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper), (status, value) = begin(context)
        #expect(status == NUB_COMPLETE); let session = try #require(value)
        defer { #expect(neantik_update_owner_dispose(session) == NUB_COMPLETE) }
        // Marker is written after SIGTERM ignore is installed in this fixture.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: helper.path + ".started") { usleep(5000) }
        let start = Date(), result = neantik_update_owner_abort(session, 400)
        #expect(result.status == NUB_COMPLETE && result.reaped == 1 && result.escalated == 1)
        #expect(Date().timeIntervalSince(start) < 1)
        let again = neantik_update_owner_abort(session, 100)
        #expect(again.status == NUB_COMPLETE && again.reaped == 1 && again.escalated == 0)
    }
    @Test func lostWaitOwnershipRefusesWithoutAnySignal() throws {
        let (root, helper) = try fixture("abnormal"); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper), (status, value) = begin(context)
        #expect(status == NUB_COMPLETE); let session = try #require(value)
        var childStatus: Int32 = 0
        #expect(waitpid(neantik_update_owner_pid(session), &childStatus, 0) > 0)
        let result = neantik_update_owner_abort(session, 100)
        #expect(result.status == NUB_WAIT && result.reaped == 0 && result.escalated == 0)
        #expect(neantik_update_owner_dispose(session) == NUB_COMPLETE)
    }
    @Test func sharedAbsoluteDeadlineIsNotResetForSecondFrame() throws {
        let (root, helper) = try fixture("ok"); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper), (_, value) = begin(context)
        let session = try #require(value); defer { cleanup(session) }
        let deadline = neantik_update_pipe_deadline(100)
        #expect(write(Data([1]), session: session, context: context, deadline: deadline) == NUB_COMPLETE)
        #expect(read(session, context).0 == NUB_COMPLETE)
        usleep(150000)
        #expect(write(Data([2]), session: session, context: context, deadline: deadline) == NUB_TIMEOUT)
        #expect(write(Data(repeating: 1, count: 128*1024+1), session: session, context: context) == NUB_REQUEST)
    }
    @Test func cancellationWhileBlockedWritingIsBounded() throws {
        let (root, helper) = try fixture("hang"); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper), (_, value) = begin(context)
        let session = try #require(value); defer { cleanup(session) }
        let cancellation = Thread { usleep(50000); context.cancel() }; cancellation.start()
        let start = Date(), status = write(Data(repeating: 1, count: 128*1024), session: session, context: context)
        #expect(status == NUB_CANCELLED && Date().timeIntervalSince(start) < 1)
    }
    @Test func rawPipeRequiresFIFOAndExactEOF() throws {
        let (root, helper) = try fixture("ok"); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper), raw = Unmanaged.passUnretained(context).toOpaque()
        let regular = open(helper.path, O_RDONLY); defer { close(regular) }
        #expect(neantik_update_pipe_expect_eof(regular, neantik_update_pipe_deadline(100), ownerPipeCancel, raw) == NUB_REQUEST)
        #expect(neantik_update_pipe_deadline(0) == 0 && neantik_update_pipe_deadline(300001) == 0)
        for trailing in [false, true] {
            var pipeFDs = [Int32](repeating: -1, count: 2); try #require(pipe(&pipeFDs) == 0)
            defer { close(pipeFDs[0]) }
            if trailing { var byte: UInt8 = 1; #expect(Darwin.write(pipeFDs[1], &byte, 1) == 1) }
            close(pipeFDs[1])
            #expect(neantik_update_pipe_expect_eof(pipeFDs[0], neantik_update_pipe_deadline(100), ownerPipeCancel, raw) == (trailing ? NUB_OUTPUT:NUB_COMPLETE))
        }
        var fds = [Int32](repeating: -1, count: 2); try #require(pipe(&fds) == 0); defer { close(fds[0]); close(fds[1]) }
        #expect(neantik_update_pipe_expect_eof(fds[0], UInt64.max, ownerPipeCancel, raw) == NUB_REQUEST)
    }
    @Test func leaderAbortDoesNotPretendDescendantsWereDrained() throws {
        let (root, helper) = try fixture("descendant"); defer { try? FileManager.default.removeItem(at:root) }
        let context = OwnerPipeContext(helper: helper), (_, value) = begin(context)
        let session = try #require(value)
        defer { #expect(neantik_update_owner_dispose(session) == NUB_COMPLETE) }
        #expect(write(Data([1]), session: session, context: context) == NUB_COMPLETE)
        let (status, bytes) = read(session, context); try #require(status == NUB_COMPLETE && bytes.count == 4)
        let pid = pid_t(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let before = try #require(DirectProcessIdentityInspector.processIdentity(pid))
        let aborted = neantik_update_owner_abort(session, 200)
        #expect(aborted.reaped == 1 && aborted.status == NUB_COMPLETE)
        let after = try #require(DirectProcessIdentityInspector.processIdentity(pid))
        #expect(after.generation == before.generation && after.userID == before.userID)
        // The descendant exits by its own bounded fixture timer. It was not
        // group-killed, and leader reaping never claimed to drain it.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: helper.path + ".descendant-done") { usleep(10000) }
        #expect(FileManager.default.fileExists(atPath: helper.path + ".descendant-done"))
        for _ in 0..<100 where DirectProcessIdentityInspector.processIdentity(pid)?.generation == before.generation { usleep(10000) }
        #expect(DirectProcessIdentityInspector.processIdentity(pid)?.generation != before.generation)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_OWNER_PIPE_SIGNED_QA_ROOT"] != nil))
    func actualSignedExactCodePositiveAndWrongCodeNegative() throws {
        let signed = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NEANTIK_OWNER_PIPE_SIGNED_QA_ROOT"]))
        let positive = signed.appendingPathComponent("Owner"), wrong = signed.appendingPathComponent("DifferentOwner")
        let actual = try DirectUpdateEmptyEntitlementCode.inspect(positive, identifier: "app.neantik.update-owner-pipe-qa")
        let alternate = try DirectUpdateEmptyEntitlementCode.inspect(wrong, identifier: "app.neantik.update-owner-pipe-qa")
        #expect(actual.cdHash != alternate.cdHash)
        for source in [positive, wrong] {
            let (root, helper) = try fixture("ok", source: source); defer { try? FileManager.default.removeItem(at:root) }
            let context = OwnerPipeContext(helper: helper, expectedCode: actual.pin), (status, value) = begin(context)
            if source == wrong { #expect(status == NUB_ADMISSION && value == nil && !context.admitted); continue }
            #expect(status == NUB_COMPLETE && context.admitted)
            let session = try #require(value); defer { cleanup(session) }
            #expect(write(Data([1]), session: session, context: context) == NUB_COMPLETE)
            #expect(read(session, context).1 == Data([1]))
        }
    }
}
