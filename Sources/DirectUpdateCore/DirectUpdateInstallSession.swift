import CryptoKit
import Darwin
import DirectInstallFilesystem
import DirectUpdateBootstrapParent
import Foundation
import Security

package enum DirectUpdateInstallSessionError: Error, Equatable {
    case request, reply, identity, custody, io, admission, cancelled, timeout, child, handoff
}

/// Fixed-width binding only, never an install capability. The receipt describes
/// the owner's already active transaction; only the owner can commit that journal.
package struct DirectUpdateBootstrapRequest: Equatable, Sendable {
    package static let byteCount = 192
    package let bytes: Data
    package var nonce: Data { bytes.subdata(in: 4..<36) }
    package var candidateDevice: UInt64 { Self.integer(bytes, 116) }
    package var candidateInode: UInt64 { Self.integer(bytes, 124) }
    package var candidateCDHash: Data { bytes.subdata(in: 132..<152) }
    package var build: UInt64 { Self.integer(bytes, 152) }
    package var runtimeSHA256: Data { bytes.subdata(in: 160..<192) }

    package init(receipt: InstallFilesystemReceipt, cdHash: Data, build: UInt64, runtimeSHA256: String) throws {
        var random = Data(count: 32)
        guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
            throw DirectUpdateInstallSessionError.request
        }
        try self.init(receipt: receipt, cdHash: cdHash, build: build, runtimeSHA256: runtimeSHA256, nonce: random)
    }
    // Internal deterministic binding for protocol controls; scalar inputs do not
    // create readiness. A live exact child and private IO remain required.
    init(receipt: InstallFilesystemReceipt, cdHash: Data, build: UInt64, runtimeSHA256: String, nonce: Data) throws {
        guard nonce.count == 32, cdHash.count == 20, build > 0, receipt.candidateDevice >= 0, receipt.candidateInode > 0 else {
            throw DirectUpdateInstallSessionError.request
        }
        var data = Data("NUB1".utf8); data.append(nonce)
        var id = receipt.transactionID.uuid; withUnsafeBytes(of: &id) { data.append(contentsOf: $0) }
        data.append(try Self.hash(receipt.journalSHA256)); data.append(try Self.hash(receipt.candidateReceiptSHA256))
        Self.append(UInt64(receipt.candidateDevice), to: &data); Self.append(receipt.candidateInode, to: &data)
        data.append(cdHash); Self.append(build, to: &data); data.append(try Self.hash(runtimeSHA256))
        self = try Self.parse(data)
    }
    private init(bytes: Data) { self.bytes = bytes }
    package static func parse(_ data: Data) throws -> Self {
        guard data.count == byteCount, data.prefix(4) == Data("NUB1".utf8),
              integer(data, 116) <= UInt64(Int64.max), integer(data, 124) > 0, integer(data, 152) > 0 else {
            throw DirectUpdateInstallSessionError.request
        }
        return .init(bytes: data)
    }
    package func reply(cdHash: Data, build: UInt64, runtimeSHA256: String) throws -> Data {
        guard cdHash == candidateCDHash, build == self.build, try Self.hash(runtimeSHA256) == self.runtimeSHA256 else {
            throw DirectUpdateInstallSessionError.reply
        }
        var data = Data("NUR1".utf8); data.append(nonce); data.append(contentsOf: SHA256.hash(data: bytes))
        data.append(cdHash); Self.append(build, to: &data); data.append(self.runtimeSHA256)
        return data
    }
    package func validateReply(_ data: Data) throws {
        guard data == (try reply(cdHash: candidateCDHash, build: build,
                                  runtimeSHA256: runtimeSHA256.map { String(format: "%02x", $0) }.joined())) else { throw DirectUpdateInstallSessionError.reply }
    }
    package var continuation: Data { Data("NUC1".utf8) + nonce }
    fileprivate func matches(_ receipt: InstallFilesystemReceipt) throws -> Bool {
        try Self(receipt: receipt, cdHash: candidateCDHash, build: build,
                 runtimeSHA256: runtimeSHA256.map { String(format: "%02x", $0) }.joined(), nonce: nonce) == self
    }
    private static func hash(_ string: String) throws -> Data {
        guard string.utf8.count == 64, string.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DirectUpdateInstallSessionError.request
        }
        var data = Data(); var offset = string.startIndex
        for _ in 0..<32 { let end = string.index(offset, offsetBy: 2); data.append(UInt8(string[offset..<end], radix: 16)!); offset = end }
        return data
    }
    private static func integer(_ data: Data, _ offset: Int) -> UInt64 {
        data.subdata(in: offset..<(offset + 8)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private static func append(_ value: UInt64, to data: inout Data) {
        var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}

private final class BootstrapSessionContext: @unchecked Sendable {
    let request: DirectUpdateBootstrapRequest, code: ProxyRelayExpectedCode
    let custody: () throws -> Void
    let onReady: (DirectUpdateCandidateReadiness) throws -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var readinessActive = false
    var process: ProxyRelayOwnerProcessIdentity?
    var error: Error?
    init(request: DirectUpdateBootstrapRequest, code: ProxyRelayExpectedCode,
         custody: @escaping () throws -> Void, onReady: @escaping (DirectUpdateCandidateReadiness) throws -> Void) {
        self.request = request; self.code = code; self.custody = custody; self.onReady = onReady
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func beginReadiness() { lock.lock(); readinessActive = true; lock.unlock() }
    func endReadiness() { lock.lock(); readinessActive = false; lock.unlock() }
    func requireReadiness(_ receipt: InstallFilesystemReceipt) throws {
        lock.lock(); let active = readinessActive; lock.unlock()
        guard active, try request.matches(receipt) else { throw DirectUpdateInstallSessionError.admission }
    }
    func validate(_ pid: pid_t) throws {
        guard !isCancelled else { throw DirectUpdateInstallSessionError.cancelled }
        try custody()
        guard let process, process.parentProcessID == getpid(),
              ProxyRelayLiveCodeVerifier.matches(processID: pid, expectedProcess: process, expectedCode: code) else {
            throw DirectUpdateInstallSessionError.identity
        }
        try custody()
        guard !isCancelled, DirectProcessIdentityInspector.processIdentity(pid) == process else {
            throw DirectUpdateInstallSessionError.identity
        }
    }
}

/// Only created inside the authenticated live child's completed private reply
/// callback. A retained object expires when its process exits/execs or custody
/// changes; it does not grant filesystem authority, and is never Codable.
final package class DirectUpdateCandidateReadiness {
    private let context: BootstrapSessionContext
    package let processID: pid_t
    fileprivate init(_ context: BootstrapSessionContext, processID: pid_t) { self.context = context; self.processID = processID }
    package func validate(receipt: InstallFilesystemReceipt) throws {
        try context.requireReadiness(receipt); try context.validate(processID); try context.requireReadiness(receipt)
    }
}

private func bootstrapAdmit(_ pid: pid_t, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let context = Unmanaged<BootstrapSessionContext>.fromOpaque(raw).takeUnretainedValue()
    do {
        guard let identity = DirectProcessIdentityInspector.processIdentity(pid), identity.userID == geteuid(),
              identity.parentProcessID == getpid() else { throw DirectUpdateInstallSessionError.identity }
        context.process = identity; try context.validate(pid); return 1
    } catch { context.error = error; return 0 }
}
private func bootstrapReady(_ pid: pid_t, _ bytes: UnsafePointer<UInt8>?, _ count: Int, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw, let bytes, count == 128 else { return 0 }
    let context = Unmanaged<BootstrapSessionContext>.fromOpaque(raw).takeUnretainedValue()
    do {
        try context.request.validateReply(Data(bytes: bytes, count: count)); try context.validate(pid)
        context.beginReadiness(); defer { context.endReadiness() }
        try context.onReady(.init(context, processID: pid))
        // Callback must commit under fresh readiness validation, release its
        // fences, then return. No cancellation reversal after durable ACK.
        return 1
    } catch { context.error = error; return 0 }
}
private func bootstrapCancel(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 1 }
    return Unmanaged<BootstrapSessionContext>.fromOpaque(raw).takeUnretainedValue().isCancelled ? 1 : 0
}

package enum DirectUpdateInstallSession {
    /// Utility-worker primitive for an independent one-shot owner. onReady is
    /// the only handoff point; production callers must supply real stopped
    /// authority/journal ACK and scope custody, not an unconditional closure.
    package static func run(candidate: URL, request: DirectUpdateBootstrapRequest, expectedCode: ProxyRelayExpectedCode,
                            validateCustody: @escaping () throws -> Void,
                            onReady: @escaping (DirectUpdateCandidateReadiness) throws -> Void,
                            timeoutMS: UInt32 = 45_000) async throws -> pid_t {
        let context = BootstrapSessionContext(request: request, code: expectedCode, custody: validateCustody, onReady: onReady)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                try validateCustody()
                let raw = Unmanaged.passUnretained(context).toOpaque()
                let result = candidate.path.withCString { path in request.bytes.withUnsafeBytes { bytes in
                    neantik_update_bootstrap_run(path, bytes.bindMemory(to: UInt8.self).baseAddress!, timeoutMS,
                        bootstrapAdmit, bootstrapReady, bootstrapCancel, raw)
                } }
                if let error = context.error { throw error }
                guard result.status == NUB_COMPLETE, result.handed_off == 1, result.continued == 1, result.reaped == 0 else {
                    if result.status == NUB_CANCELLED { throw DirectUpdateInstallSessionError.cancelled }
                    if result.status == NUB_TIMEOUT { throw DirectUpdateInstallSessionError.timeout }
                    throw DirectUpdateInstallSessionError.child
                }
                // Handoff cannot be undone by cancellation after onReady ACK.
                return result.process_id
            }.value
        } onCancel: { context.cancel() }
    }
}
