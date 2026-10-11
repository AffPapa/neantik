import CryptoKit
import Darwin
import DirectAssessmentParent
import Foundation
import Testing
@testable import NeAntik
@testable import DirectUpdateCore

private final class ParentFixtureContext {
    var admitted = true, cancelAfterAdmission = false, didAdmit = false
    var admissionHook: ((pid_t) -> Void)?
    var cancelAt: Date?
    var expectedCode: ProxyRelayExpectedCode?
}
private func fixtureAdmit(_ pid: pid_t, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    let context = Unmanaged<ParentFixtureContext>.fromOpaque(raw!).takeUnretainedValue()
    context.didAdmit = true; context.admissionHook?(pid)
    if let code = context.expectedCode {
        guard let identity = ProxyRelaySocketOwnerInspector.processIdentity(pid),
              identity.parentProcessID == getpid(),
              ProxyRelayLiveCodeVerifier.matches(processID: pid, expectedProcess: identity, expectedCode: code) else { return 0 }
    }
    return context.admitted ? 1 : 0
}
private func fixtureCancel(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    let context = Unmanaged<ParentFixtureContext>.fromOpaque(raw!).takeUnretainedValue()
    return (context.cancelAfterAdmission && context.didAdmit) || (context.cancelAt.map { Date() >= $0 } ?? false) ? 1 : 0
}
private final class AssessmentParentBundle {}
@Suite(.serialized) struct DirectAssessmentParentTests {
    private let refusal = "{\"schema\":2,\"status\":5,\"gatekeeperAccepted\":false,\"offlineTicketAccepted\":false,\"onlineRevocationCheckCompleted\":false,\"onlineDateAdmitted\":false,\"systemErrorCode\":0,\"installAuthorized\":false}\n"
    @Test func canonicalPrivateTemporaryPathIsNotRewrittenByFoundation() throws {
        let url = URL(fileURLWithPath: "/private/tmp/neantik-admission-fixture/NeAntik.app")
        let hash = Data(repeating: 7, count: 20)
        let request = try DirectAssessmentParent.request(app: url, cdHash: hash)
        #expect(request.prefix(4) == Data("NAA2".utf8))
        #expect(request[4..<24] == hash)
        #expect(String(decoding: request.dropFirst(32), as: UTF8.self) == url.path)
        #expect(request.count == 32 + url.path.utf8.count)
        #expect(throws: DirectAssessmentParentError.request) {
            try DirectAssessmentParent.request(app: url, cdHash: Data(repeating: 0, count: 19))
        }
        #expect(throws: DirectAssessmentParentError.request) {
            try DirectAssessmentParent.request(app: URL(string: "https://example.com/NeAntik.app")!, cdHash: hash)
        }
        #expect(throws: DirectAssessmentParentError.request) {
            try DirectAssessmentParent.request(app: URL(string: "file:///private/tmp/a/../NeAntik.app")!, cdHash: hash)
        }
    }
    private func fixture() throws -> (URL, URL) {
        var binary: URL?
        for base in [Bundle(for: AssessmentParentBundle.self).bundleURL, URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()] {
            var directory = base
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("NeAntikAssessmentParentFixture")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { binary = candidate; break }
                directory.deleteLastPathComponent()
            }
        }
        let selected = try #require(binary)
        let root = URL(fileURLWithPath: "/private/tmp/neantik-assessment-parent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent("fixture")
        try FileManager.default.copyItem(at: selected, to: target)
        return (root, target)
    }
    private func run(_ helper: URL, _ input: String, context: ParentFixtureContext = .init(), deadline: UInt32 = 2_000) -> NeAntikAssessmentParentResult {
        let bytes = Data(input.utf8)
        return helper.path.withCString { path in bytes.withUnsafeBytes { data in
            neantik_assessment_parent_run(path, data.bindMemory(to: UInt8.self).baseAddress, data.count, deadline, fixtureAdmit, fixtureCancel, Unmanaged.passUnretained(context).toOpaque())
        } }
    }
    @Test func actualChildReceivesEOFAndIsReaped() throws {
        let (root, helper) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var result = run(helper, "ok")
        #expect(result.status == NAP_COMPLETE, "status=\(result.status), exit=\(result.exit_code), normal=\(result.exited_normally), resumed=\(result.continued), reaped=\(result.reaped), outputBytes=\(result.output_bytes)")
        #expect(result.reaped == 1 && result.continued == 1 && result.exited_normally == 1 && result.exit_code == 1)
        let bytes = withUnsafeBytes(of: &result.output) { Data($0.prefix(Int(result.output_bytes))) }
        #expect(try DirectAssessmentReply.parse(bytes, exitCode: result.exit_code, normalExit: true, now: 812_000_000) == .refused(status: 5, gatekeeper: false, offline: false, online: false, onlineDate: false, systemError: 0))
        var status: Int32 = 0; errno = 0
        #expect(waitpid(result.process_id, &status, WNOHANG) == -1 && errno == ECHILD)
    }
    @Test(arguments: ["hang", "descendant", "closed-stdio", "stderr", "flood", "abnormal"])
    func actualBrokenChildControls(mode: String) throws {
        let (root, helper) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(); var result = run(helper, mode, deadline: 200)
        #expect(result.reaped == 1 && result.continued == 1)
        if mode == "hang" || mode == "descendant" || mode == "closed-stdio" { #expect(result.status == NAP_TIMEOUT) }
        else if mode == "abnormal" { #expect(result.status == NAP_COMPLETE && result.exited_normally == 0) }
        else { #expect(result.status == NAP_OUTPUT) }
        #expect(Date().timeIntervalSince(start) < 3)
        var status: Int32 = 0; errno = 0
        #expect(waitpid(result.process_id, &status, WNOHANG) == -1 && errno == ECHILD)
        if mode == "descendant" {
            let data = withUnsafeBytes(of: &result.output) { Data($0.prefix(Int(result.output_bytes))) }
            let pid = try #require(Int32(String(decoding: data, as: UTF8.self)))
            // Reparented descendant can briefly be an init-owned zombie; require
            // that it is no longer running, not that this parent may reap it.
            var info = proc_bsdinfo()
            let count = withUnsafeMutableBytes(of: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0.baseAddress, Int32($0.count)) }
            #expect(count == 0 || info.pbi_status == SZOMB)
        }
    }
    @Test(arguments: ["autoreap-ignore", "autoreap-no-wait"])
    func childAutoreapPolicyRefusesSpawn(mode: String) throws {
        let (root, helper) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let result = run(helper, mode)
        #expect(result.status == NAP_COMPLETE && result.exited_normally == 1 && result.exit_code == 1 && result.reaped == 1)
    }
    @Test func runningCancellationKillsAndReaps() throws {
        let (root, helper) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = ParentFixtureContext(); context.admissionHook = { _ in context.cancelAt = Date().addingTimeInterval(0.15) }
        let result = run(helper, "hang", context: context, deadline: 1_000)
        #expect(result.status == NAP_CANCELLED && result.reaped == 1 && result.continued == 1 && result.output_bytes == 5)
    }
    @Test func deniedPausedGuestNeverContinues() throws {
        let (root, helper) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = ParentFixtureContext(); context.admitted = false
        context.admissionHook = { pid in
            #expect(ProxyRelaySocketOwnerInspector.processIdentity(pid)?.parentProcessID == getpid())
            #expect(ProxyRelaySocketOwnerInspector.processIdentity(pid)?.userID == geteuid())
        }
        let result = run(helper, "flood", context: context)
        #expect(context.didAdmit && result.status == NAP_ADMISSION && result.continued == 0 && result.reaped == 1 && result.output_bytes == 0)
    }
    @Test func cancellationWhileSuspendedReapsWithoutExecution() throws {
        let (root, helper) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = ParentFixtureContext(); context.cancelAfterAdmission = true
        let result = run(helper, "flood", context: context)
        #expect(result.status == NAP_CANCELLED && result.continued == 0 && result.reaped == 1 && result.output_bytes == 0)
    }
    @Test func childHasFixedEnvironmentAndNoInheritedDescriptor() throws {
        let (root, helper) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        setenv("NEANTIK_ASSESSMENT_TEST_SECRET", "synthetic", 1); defer { unsetenv("NEANTIK_ASSESSMENT_TEST_SECRET") }
        #expect(run(helper, "environment").exit_code == 1)
        let fd = open("/dev/null", O_RDONLY); defer { close(fd) }; #expect(fd > 2)
        #expect(run(helper, "descriptor:\(fd)").exit_code == 1)
    }
    @Test func strictReplyPositiveAndNegativeControls() throws {
        let success = "{\"schema\":2,\"status\":0,\"offlineTicketDate\":811900000.000000,\"onlineTicketDate\":811950000.000000,\"onlineRevocationCheckCompleted\":true,\"freshRemoteResponseProven\":false,\"installAuthorized\":false}\n"
        #expect(try DirectAssessmentReply.parse(Data(success.utf8), exitCode: 0, normalExit: true, now: 812_000_000) == .observed(offlineTicketDate: 811900000, onlineTicketDate: 811950000))
        let absentDate = success.replacingOccurrences(of: "811950000.000000", with: "null")
        #expect(try DirectAssessmentReply.parse(Data(absentDate.utf8), exitCode: 0, normalExit: true, now: 812_000_000) == .observed(offlineTicketDate: 811900000, onlineTicketDate: nil))
        #expect(try DirectAssessmentReply.parse(Data(refusal.utf8), exitCode: 1, normalExit: true, now: 812_000_000).installAuthorized == false)
        for bad in [success + "{}", success.replacingOccurrences(of: "\"schema\":2", with: "\"schema\":2,\"schema\":2"),
                    success.replacingOccurrences(of: "false", with: "0"), success.replacingOccurrences(of: "811900000.000000", with: "NaN"),
                    success.replacingOccurrences(of: "811900000.000000", with: "900000000.000000"),
                    success.replacingOccurrences(of: "811900000.000000", with: "null"),
                    success.replacingOccurrences(of: "811950000.000000", with: "0.000000"),
                    success.replacingOccurrences(of: "811950000.000000", with: "900000000.000000"),
                    success.replacingOccurrences(of: "811950000.000000", with: "NaN"),
                    absentDate.replacingOccurrences(of: "\"onlineRevocationCheckCompleted\":true", with: "\"onlineRevocationCheckCompleted\":false"),
                    absentDate.replacingOccurrences(of: "\"onlineRevocationCheckCompleted\":true", with: "\"onlineRevocationCheckCompleted\":1"),
                    absentDate.replacingOccurrences(of: "\"schema\":2", with: "\"schema\":1"),
                    success.replacingOccurrences(of: "\"onlineRevocationCheckCompleted\":true,", with: ""),
                    success.replacingOccurrences(of: "\"schema\"", with: "\"sch\\u0065ma\""),
                    refusal.replacingOccurrences(of: "\"gatekeeperAccepted\":false", with: "\"gatekeeperAccepted\":true"),
                    refusal.replacingOccurrences(of: "\"systemErrorCode\":0", with: "\"systemErrorCode\":9223372036854775808"),
                    "{}\n", String(repeating: "x", count: 1025)] {
            #expect(throws: DirectAssessmentParentError.reply) { try DirectAssessmentReply.parse(Data(bad.utf8), exitCode: bad.contains("\"status\":5") ? 1 : 0, normalExit: true, now: 812_000_000) }
        }
        #expect(throws: DirectAssessmentParentError.reply) { try DirectAssessmentReply.parse(Data(success.utf8), exitCode: 1, normalExit: true, now: 812_000_000) }
        #expect(throws: DirectAssessmentParentError.reply) { try DirectAssessmentReply.parse(Data(success.utf8), exitCode: 0, normalExit: false, now: 812_000_000) }
    }
    @Test func onlineRefusalsAndChangedBindingHaveConsistentVersionedStates() throws {
        for (completed, admitted, error) in [(false, true, Int64(EACCES)), (false, true, 1), (true, false, 0), (false, false, 0)] {
            let line = "{\"schema\":2,\"status\":8,\"gatekeeperAccepted\":true,\"offlineTicketAccepted\":true,\"onlineRevocationCheckCompleted\":\(completed),\"onlineDateAdmitted\":\(admitted),\"systemErrorCode\":\(error),\"installAuthorized\":false}\n"
            #expect(try DirectAssessmentReply.parse(Data(line.utf8), exitCode: 1, normalExit: true, now: 812_000_000) == .refused(status: 8, gatekeeper: true, offline: true, online: completed, onlineDate: admitted, systemError: error))
        }
        let changed = "{\"schema\":2,\"status\":9,\"gatekeeperAccepted\":true,\"offlineTicketAccepted\":true,\"onlineRevocationCheckCompleted\":true,\"onlineDateAdmitted\":true,\"systemErrorCode\":0,\"installAuthorized\":false}\n"
        #expect(try DirectAssessmentReply.parse(Data(changed.utf8), exitCode: 1, normalExit: true, now: 812_000_000) == .refused(status: 9, gatekeeper: true, offline: true, online: true, onlineDate: true, systemError: 0))
        #expect(throws: DirectAssessmentParentError.reply) { try DirectAssessmentReply.parse(Data(changed.replacingOccurrences(of: "\"status\":9", with: "\"status\":8").utf8), exitCode: 1, normalExit: true, now: 812_000_000) }
        #expect(throws: DirectAssessmentParentError.reply) { try DirectAssessmentReply.parse(Data(changed.replacingOccurrences(of: "\"systemErrorCode\":0", with: "\"systemErrorCode\":13").utf8), exitCode: 1, normalExit: true, now: 812_000_000) }
    }
    @Test func separatelySignedHelperQualification() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEANTIK_ASSESSMENT_PARENT_QA_ROOT"],
              let app = ProcessInfo.processInfo.environment["NEANTIK_ASSESSMENT_PARENT_QA_APP"] else { return }
        let root = URL(fileURLWithPath: path), file = root.appendingPathComponent("Helpers/NeAntikUpdateAssessment")
        let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        let helper = try DirectAssessmentHelper.qualification(in: root, payloadSHA256: hash)
        let parent = root.appendingPathComponent("Helpers")
        guard chmod(parent.path, 0o777) == 0 else { throw DirectAssessmentParentError.helper }
        #expect(throws: DirectAssessmentParentError.helper) { try helper.validate() }
        guard chmod(parent.path, 0o700) == 0 else { throw DirectAssessmentParentError.helper }
        try helper.validate()
        guard chmod(file.path, 0o601) == 0 else { throw DirectAssessmentParentError.helper }
        #expect(throws: DirectAssessmentParentError.helper) { try DirectAssessmentHelper.qualification(in: root, payloadSHA256: hash) }
        guard chmod(file.path, 0o755) == 0 else { throw DirectAssessmentParentError.helper }
        // chmod modifies ctime: the previously captured handle must stay stale.
        #expect(throws: DirectAssessmentParentError.helper) { try helper.validate() }
        let fresh = try DirectAssessmentHelper.qualification(in: root, payloadSHA256: hash)
        let reply = try await DirectAssessmentParent.qualification(app: URL(fileURLWithPath: app), helper: fresh)
        #expect(reply == .refused(status: 5, gatekeeper: false, offline: false, online: false, onlineDate: false, systemError: 0))
    }
    @Test func signedSameTeamDifferentCodeRefusesAndTaskCancellationDrains() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEANTIK_ASSESSMENT_PARENT_QA_ROOT"],
              let alternate = ProcessInfo.processInfo.environment["NEANTIK_ASSESSMENT_PARENT_QA_ALTERNATE"] else { return }
        let root = URL(fileURLWithPath: path), file = root.appendingPathComponent("Helpers/NeAntikUpdateAssessment")
        let helperHash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        let helper = try DirectAssessmentHelper.qualification(in: root, payloadSHA256: helperHash)
        let otherRoot = URL(fileURLWithPath: alternate), other = otherRoot.appendingPathComponent("Helpers/NeAntikUpdateAssessment")
        let otherHash = SHA256.hash(data: try Data(contentsOf: other)).map { String(format: "%02x", $0) }.joined()
        #expect(otherHash != helperHash)
        let otherHelper = try DirectAssessmentHelper.qualification(in: otherRoot, payloadSHA256: otherHash)
        let negative = ParentFixtureContext(); negative.expectedCode = helper.expectedCode
        let refused = run(other, "ok", context: negative)
        #expect(refused.status == NAP_ADMISSION && refused.continued == 0 && refused.reaped == 1 && refused.output_bytes == 0)
        let positive = ParentFixtureContext(); positive.expectedCode = otherHelper.expectedCode
        let accepted = run(other, "ok", context: positive)
        #expect(accepted.status == NAP_COMPLETE && accepted.continued == 1 && accepted.reaped == 1 && accepted.exit_code == 1)
        let marker = otherRoot.appendingPathComponent("ready")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let task = Task { try await DirectAssessmentParent.qualification(app: otherRoot.appendingPathComponent("hang"), helper: otherHelper) }
        do {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: marker.path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled helper returned observation") }
            catch { #expect(error as? DirectAssessmentParentError == .cancelled || error is CancellationError) }
            try? FileManager.default.removeItem(at: marker)
        } catch { task.cancel(); _ = try? await task.value; throw error }
    }

}
