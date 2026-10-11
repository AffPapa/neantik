import Darwin
import DirectAssessmentParent
import DirectInstallFilesystem
import Foundation

package enum DirectAssessmentParentError: Error, Equatable { case helper, request, reply, spawn, admission, cancelled, timeout, output, input, wait, io }

/// A system observation, never an installation capability or proof that an
/// online lookup fetched a fresh response. Not decodable from external JSON.
package struct DirectSystemAssessmentObservation: Sendable {
    package let reply: DirectAssessmentReply
    package let managerCDHash: Data
    package var installAuthorized: Bool { false }
    fileprivate init(reply: DirectAssessmentReply, managerCDHash: Data) { self.reply = reply; self.managerCDHash = managerCDHash }
}

private final class AssessmentParentContext: @unchecked Sendable {
    let helper: DirectAssessmentHelper
    private let lock = NSLock()
    private var cancelled = false
    init(_ helper: DirectAssessmentHelper) { self.helper = helper }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func admit(_ pid: pid_t) -> Bool {
        guard !isCancelled, let identity = DirectProcessIdentityInspector.processIdentity(pid),
              identity.userID == geteuid(), identity.parentProcessID == getpid() else { return false }
        do {
            try helper.validate()
            guard ProxyRelayLiveCodeVerifier.matches(processID: pid, expectedProcess: identity, expectedCode: helper.expectedCode) else { return false }
            try helper.validate()
            return !isCancelled && DirectProcessIdentityInspector.processIdentity(pid) == identity
        } catch { return false }
    }
}
private func assessmentAdmit(_ pid: pid_t, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }; return Unmanaged<AssessmentParentContext>.fromOpaque(raw).takeUnretainedValue().admit(pid) ? 1 : 0
}
private func assessmentCancel(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 1 }; return Unmanaged<AssessmentParentContext>.fromOpaque(raw).takeUnretainedValue().isCancelled ? 1 : 0
}

package enum DirectAssessmentParent {
    /// Run while the owning stage's borrow holds custody, including on refusal.
    /// Catch operation errors inside the borrow so its postcondition still runs.
    package static func observe(stage: ExtractedUpdateApp, helper: DirectAssessmentHelper) async throws -> DirectSystemAssessmentObservation {
        try await work(helper: helper) { context in
            let result: Result<DirectSystemAssessmentObservation, Error> = try stage.withValidatedApp { url in
                Result { try observe(url: url, context: context) }
            }
            return try result.get()
        }
    }
    package static func observe(stage: ExtractedUpdateApp, signature: DirectUpdateStageSignature,
                        helper: DirectAssessmentHelper) async throws -> DirectSystemAssessmentObservation {
        try await work(helper: helper) { context in
            try signature.requireBinding(to: stage)
            let result: Result<DirectSystemAssessmentObservation, Error> = try stage.withValidatedApp { url in
                Result {
                    let hash = signature.manager.cdHash
                    let reply = try run(app: url, cdHash: hash, context: context, timeoutMS: 185_000)
                    return .init(reply: reply, managerCDHash: hash)
                }
            }
            try signature.requireBinding(to: stage)
            return try result.get()
        }
    }
    package static func observe(candidate: PreparedInstallSlot, helper: DirectAssessmentHelper) async throws -> DirectSystemAssessmentObservation {
        // The slot is never accessed outside this one worker; caller must retain
        // its installation lease and must not begin a transaction concurrently.
        let slot = AssessmentCandidate(candidate)
        return try await work(helper: helper) { context in
            let result: Result<DirectSystemAssessmentObservation, Error> = try slot.value.withValidatedCandidate { url in
                Result { try observe(url: url, context: context) }
            }
            return try result.get()
        }
    }
    private final class AssessmentCandidate: @unchecked Sendable {
        let value: PreparedInstallSlot
        init(_ value: PreparedInstallSlot) { self.value = value }
    }
    private static func work<T: Sendable>(helper: DirectAssessmentHelper, operation: @escaping @Sendable (AssessmentParentContext) throws -> T) async throws -> T {
        let context = AssessmentParentContext(helper)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let worker = Task.detached(priority: .utility) { try operation(context) }
            let result = try await worker.value
            try Task.checkCancellation(); return result
        } onCancel: { context.cancel() }
    }
    private static func observe(url: URL, context: AssessmentParentContext) throws -> DirectSystemAssessmentObservation {
        guard !context.isCancelled else { throw DirectAssessmentParentError.cancelled }
        let signature = try DirectUpdateCodeSignature.inspect(url, role: .manager)
        let reply = try run(app: url, cdHash: signature.cdHash, context: context, timeoutMS: 185_000)
        guard !context.isCancelled else { throw DirectAssessmentParentError.cancelled }
        return .init(reply: reply, managerCDHash: signature.cdHash)
    }
    package static func request(app: URL, cdHash: Data) throws -> Data {
        let bytes = Array(app.path.utf8)
        // Foundation's standardizedFileURL can rewrite the macOS /private/tmp
        // spelling to /tmp. Check syntax without that alias rewrite; the C
        // helper independently requires exact realpath + lstat owner/directory
        // before Security assessment, under the stage's sealed custody borrow.
        let components = app.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard app.isFileURL, app.path.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              app.path == app.path.precomposedStringWithCanonicalMapping, !bytes.contains(0),
              !bytes.isEmpty, bytes.count < Int(PATH_MAX), cdHash.count == 20 else { throw DirectAssessmentParentError.request }
        var data = Data("NAA2".utf8); data.append(cdHash)
        for value in [UInt32(2), UInt32(bytes.count)] {
            var be = value.bigEndian; withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: bytes); return data
    }
    private static func run(app: URL, cdHash: Data, context: AssessmentParentContext, timeoutMS: UInt32) throws -> DirectAssessmentReply {
        try context.helper.validate()
        let input = try request(app: app, cdHash: cdHash)
        let raw = Unmanaged.passUnretained(context).toOpaque()
        var result = context.helper.url.path.withCString { path in input.withUnsafeBytes { bytes in
            neantik_assessment_parent_run(path, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, timeoutMS, assessmentAdmit, assessmentCancel, raw)
        } }
        try context.helper.validate()
        guard result.status == NAP_COMPLETE, result.reaped == 1, result.continued == 1 else {
            switch Int(result.status) {
            case NAP_SPAWN: throw DirectAssessmentParentError.spawn
            case NAP_ADMISSION: throw DirectAssessmentParentError.admission
            case NAP_CANCELLED: throw DirectAssessmentParentError.cancelled
            case NAP_TIMEOUT: throw DirectAssessmentParentError.timeout
            case NAP_OUTPUT: throw DirectAssessmentParentError.output
            case NAP_INPUT: throw DirectAssessmentParentError.input
            case NAP_WAIT: throw DirectAssessmentParentError.wait
            default: throw DirectAssessmentParentError.io
            }
        }
        let output = withUnsafeBytes(of: &result.output) { Data($0.prefix(Int(result.output_bytes))) }
        return try .parse(output, exitCode: result.exit_code, normalExit: result.exited_normally == 1, now: Date().timeIntervalSinceReferenceDate)
    }
    #if DEBUG
    /// Actual child admission with the independently qualified QA identity.
    /// Invalid manager hash deliberately stops before online ticket lookup.
    static func qualification(app: URL, helper: DirectAssessmentHelper, timeoutMS: UInt32 = 2_000) async throws -> DirectAssessmentReply {
        try await work(helper: helper) { context in
            try run(app: app, cdHash: Data(repeating: 0, count: 20), context: context, timeoutMS: timeoutMS)
        }
    }
    #endif
}
