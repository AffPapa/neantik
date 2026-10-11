import Darwin
import DirectUpdateBootstrapParent
import Foundation

package enum DirectUpdateOwnerClientError: LocalizedError {
    case state, transport, cleanup
    package var errorDescription: String? {
        switch self {
        case .state: "Эта проверка обновления уже завершена. Выбери файлы заново."
        case .transport: "Установщик не подтвердил обновление. Приложение не заменено. Повтори проверку файлов."
        case .cleanup: "Завершение установщика не подтверждено. Не начинай другую установку; закрой приложение и повтори запуск."
        }
    }
}

/// App-owned, one-use client. All native session calls share one utility queue;
/// only the cancellation flag may change concurrently. No MCP entry or caller
/// supplies the installed app, public key, helper or process to signal.
final package class DirectUpdateOwnerClient: @unchecked Sendable {
    private let worker: OwnerClientWorker
    package init(auditIsolation: DirectUpdateAuditIsolation? = nil,
                 prepareAuditIsolation: (@Sendable () throws -> DirectUpdateAuditIsolation)? = nil) {
        worker = OwnerClientWorker(auditIsolation: auditIsolation, prepareAuditIsolation: prepareAuditIsolation)
    }
    package func inspect(archive: URL, manifest: Data) async throws -> DirectUpdateOwnerOffer {
        try await withTaskCancellationHandler {
            try await worker.perform { try $0.inspect(archive: archive, manifest: manifest) }
        } onCancel: { self.worker.cancellation.request() }
    }
    /// Only valid for this client's retained offer. Completion means the owner
    /// received consent and owns its lifetime, not that the app was installed.
    package func consentAndHandoff() async throws {
        try await worker.perform { try $0.consentAndHandoff() }
    }
    package func cancelAndDrain() async throws {
        worker.cancellation.request()
        try await worker.perform { try $0.cancelAndDrain() }
    }
    deinit { worker.abandon() }
}

private final class OwnerClientCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    func request() { lock.lock(); requested = true; lock.unlock() }
    var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}
private func ownerClientCancel(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    return Unmanaged<OwnerClientCancellation>.fromOpaque(raw).takeUnretainedValue().isRequested ? 1 : 0
}
private final class OwnerClientAdmission {
    let policy: DirectUpdateInstalledPolicy, workspace: DirectUpdateOwnerWorkspace
    let cancellation: OwnerClientCancellation
    init(policy: DirectUpdateInstalledPolicy, workspace: DirectUpdateOwnerWorkspace, cancellation: OwnerClientCancellation) {
        self.policy = policy; self.workspace = workspace; self.cancellation = cancellation
    }
}
private func ownerClientAdmissionCancel(_ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 1 }
    return Unmanaged<OwnerClientAdmission>.fromOpaque(raw).takeUnretainedValue().cancellation.isRequested ? 1 : 0
}
private func ownerClientAdmit(_ pid: pid_t, _ raw: UnsafeMutableRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let context = Unmanaged<OwnerClientAdmission>.fromOpaque(raw).takeUnretainedValue()
    do {
        try context.policy.validate(); try context.workspace.validate()
        guard let identity = DirectProcessIdentityInspector.processIdentity(pid),
              identity.userID == geteuid(), identity.parentProcessID == getpid(),
              ProxyRelayLiveCodeVerifier.matches(processID: pid, expectedProcess: identity,
                  expectedCode: context.workspace.owner.expectedCode) else { return 0 }
        try context.workspace.validate(); try context.policy.validate()
        return DirectProcessIdentityInspector.processIdentity(pid) == identity ? 1 : 0
    } catch { return 0 }
}

private final class OwnerClientWorker: @unchecked Sendable {
    let cancellation = OwnerClientCancellation()
    private var auditIsolation: DirectUpdateAuditIsolation?
    private let prepareAuditIsolation: (@Sendable () throws -> DirectUpdateAuditIsolation)?
    init(auditIsolation: DirectUpdateAuditIsolation?, prepareAuditIsolation: (@Sendable () throws -> DirectUpdateAuditIsolation)?) {
        self.auditIsolation = auditIsolation; self.prepareAuditIsolation = prepareAuditIsolation
    }
    private let queue = DispatchQueue(label: "app.neantik.update-client", qos: .utility)
    private var session: OpaquePointer?
    private var admission: OwnerClientAdmission?
    private var request: DirectUpdateOwnerInit?, offer: DirectUpdateOwnerOffer?
    private var started = false, handedOff = false
    // A failed bounded abort cannot silently free a still-owned native child.
    private static let retentionLock = NSLock()
    private static var unfinished: [OwnerClientWorker] = []

    func perform<T: Sendable>(_ action: @escaping @Sendable (OwnerClientWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try action(self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func inspect(archive: URL, manifest: Data) throws -> DirectUpdateOwnerOffer {
        guard !started, session == nil else { throw DirectUpdateOwnerClientError.state }
        started = true
        do {
            if cancellation.isRequested { throw CancellationError() }
            if let prepareAuditIsolation { auditIsolation = try prepareAuditIsolation() }
            try auditIsolation?.validate()
            guard let executable = DirectUpdateProcessInventory.path(getpid()) else { throw DirectUpdateInstallSessionError.identity }
            let installed = try DirectUpdateOwnerAuthentication.installedApp(executable: URL(fileURLWithPath: executable))
            let policy = try DirectUpdateInstalledPolicy.inspect(installedApp: installed)
            let code = try ProxyRelayExpectedCode.qualifiedPin(at: installed,
                expectedIdentifier: DirectUpdateCodeRole.manager.identifier,
                expectedTeamIdentifier: DirectUpdateCodeSignature.team, expectedCDHash: policy.managerCDHash)
            guard let identity = DirectProcessIdentityInspector.processIdentity(getpid()),
                  ProxyRelayLiveCodeVerifier.matches(processID: getpid(), expectedProcess: identity, expectedCode: code) else {
                throw DirectUpdateInstallSessionError.identity
            }
            // Before owner launch; afterwards this inventory would see our own
            // owner as busy. Final authority is still checked after GUI exit.
            try DirectUpdateStoppedAuthority.requireQuietInventory()
            let workspace = try DirectUpdateOwnerWorkspace.prepare(policy: policy)
            let context = OwnerClientAdmission(policy: policy, workspace: workspace, cancellation: cancellation)
            admission = context
            let input = try DirectUpdateOwnerInit(archive: archive, manifest: manifest, auditIsolation: auditIsolation); request = input
            let status = withExtendedLifetime(context) {
                workspace.owner.url.path.withCString {
                    neantik_update_owner_begin($0, 10_000, ownerClientAdmit, ownerClientAdmissionCancel,
                        Unmanaged.passUnretained(context).toOpaque(), &session)
                }
            }
            if status != NUB_COMPLETE { try abortAndDispose() }
            try requireComplete(status)
            try write(input.bytes); try write(manifest)
            let found = try DirectUpdateOwnerOffer.parse(read(cancellable: true), request: input)
            if cancellation.isRequested { throw CancellationError() }
            offer = found; return found
        } catch {
            if cancellation.isRequested, session != nil {
                do { try cancelAndDrain() } catch { throw DirectUpdateOwnerClientError.cleanup }
                throw CancellationError()
            }
            try abortAndDispose()
            throw error
        }
    }
    func consentAndHandoff() throws {
        guard let request, let offer, let session, !handedOff, !cancellation.isRequested else {
            throw DirectUpdateOwnerClientError.state
        }
        do {
            try auditIsolation?.validate(); try admission?.policy.validate(); try admission?.workspace.validate()
            try write(DirectUpdateOwnerConsent.command(.commit, request: request, offer: offer))
            try DirectUpdateOwnerConsent.validateAccepted(read(cancellable: false), request: request, offer: offer)
            try requireComplete(neantik_update_owner_handoff(session))
            handedOff = true
            try requireComplete(neantik_update_owner_dispose(session)); self.session = nil
            admission = nil
        } catch {
            if !handedOff { try abortAndDispose() }
            throw error
        }
    }
    func cancelAndDrain() throws {
        guard !handedOff else { throw DirectUpdateOwnerClientError.state }
        guard session != nil else { return }
        guard let request else { try abortAndDispose(); throw DirectUpdateOwnerClientError.cleanup }
        do {
            try write(DirectUpdateOwnerConsent.earlyCancel(request: request))
            var frame = try read(cancellable: false, timeoutMS: 60_000)
            if frame != DirectUpdateOwnerConsent.cancelled(request: request) {
                // An offer can race the cancellation flag. It is observation,
                // never a drained acknowledgement and never consent.
                _ = try DirectUpdateOwnerOffer.parse(frame, request: request)
                frame = try read(cancellable: false, timeoutMS: 60_000)
            }
            guard frame == DirectUpdateOwnerConsent.cancelled(request: request) else { throw DirectUpdateOwnerProtocolError.binding }
            try abortAndDispose()
        } catch {
            try abortAndDispose()
            throw DirectUpdateOwnerClientError.cleanup
        }
    }
    func abandon() {
        cancellation.request()
        queue.async {
            do { try self.cancelAndDrain() }
            catch { try? self.abortAndDispose() }
        }
    }
    private func abortAndDispose() throws {
        guard let session, !handedOff else { return }
        let cleanup = neantik_update_owner_abort(session, 2_000)
        let disposed = neantik_update_owner_dispose(session) == NUB_COMPLETE
        if disposed { self.session = nil; admission = nil; offer = nil }
        guard cleanup.reaped == 1, cleanup.status == NUB_COMPLETE, disposed else {
            if !disposed {
                Self.retentionLock.lock()
                if !Self.unfinished.contains(where: { $0 === self }) { Self.unfinished.append(self) }
                Self.retentionLock.unlock()
            }
            throw DirectUpdateOwnerClientError.cleanup
        }
    }
    private func write(_ bytes: Data) throws {
        guard let session else { throw DirectUpdateOwnerClientError.state }
        try requireComplete(bytes.withUnsafeBytes {
            neantik_update_owner_write_frame(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count,
                neantik_update_pipe_deadline(10_000), ownerClientCancel, nil)
        })
    }
    private func read(cancellable: Bool, timeoutMS: UInt32 = 300_000) throws -> Data {
        guard let session else { throw DirectUpdateOwnerClientError.state }
        var bytes = Data(count: 128 * 1_024), received = 0
        let raw = cancellable ? Unmanaged.passUnretained(cancellation).toOpaque() : nil
        let status = bytes.withUnsafeMutableBytes {
            neantik_update_owner_read_frame_boundary(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count,
                &received, neantik_update_pipe_deadline(timeoutMS), 5_000, ownerClientCancel, raw)
        }
        try requireComplete(status); return bytes.prefix(received)
    }
    private func requireComplete(_ status: Int32) throws {
        switch Int(status) {
        case NUB_COMPLETE: return
        case NUB_CANCELLED: throw CancellationError()
        default: throw DirectUpdateOwnerClientError.transport
        }
    }
}
