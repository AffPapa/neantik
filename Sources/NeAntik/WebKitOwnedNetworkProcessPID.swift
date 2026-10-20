import Darwin
import Foundation
import WebKit

/// Resolves the NetworkProcess PID only from NeAntik's attested, source-built
/// WebKit image. The same-named export in Apple's system WebKit is private and
/// is deliberately never searched through RTLD_DEFAULT.
enum WebKitOwnedNetworkProcessPID {
    static let symbolName = "WKWebsiteDataStoreGetNetworkProcessIdentifier"

    /// Process-lifetime identity for a WebKit NetworkProcess. `pid` alone can
    /// be reused; the kernel start timestamp is sampled before and after the
    /// ownership checks. This is a locator, not code-signature proof: the
    /// broker must still attest the live executable before authorizing flows.
    struct Owner: Equatable, Sendable {
        let pid: pid_t
        let startedAtSeconds: Int64
        let startedAtMicroseconds: Int32
        let userID: uid_t
        let parentPID: pid_t
    }

    struct ProcessSnapshot: Equatable, Sendable {
        let pid: pid_t
        let startedAtSeconds: Int64
        let startedAtMicroseconds: Int32
        let userID: uid_t
        let parentPID: pid_t

        var isValid: Bool {
            pid > 1 && startedAtSeconds > 0 &&
                (0..<1_000_000).contains(startedAtMicroseconds) && parentPID > 0
        }

        static func current(_ pid: pid_t) -> ProcessSnapshot? {
            guard let value = DirectProcessIdentityInspector.processIdentity(pid) else { return nil }
            return .init(pid: pid,
                         startedAtSeconds: value.generation.startSeconds,
                         startedAtMicroseconds: value.generation.startMicroseconds,
                         userID: value.userID,
                         parentPID: value.parentProcessID)
        }
    }

    enum Failure: Error, Equatable {
        case imageNotLoaded
        case symbolMissing
        case invalidProcessIdentifier
        case invalidProcessIdentity
    }

    typealias PIDFunction = @convention(c) (UnsafeRawPointer?) -> Int32
    typealias ImageOpener = (String, Int32) -> UnsafeMutableRawPointer?
    typealias SymbolLookup = (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer?
    typealias ImageCloser = (UnsafeMutableRawPointer) -> Void
    typealias FunctionCall = (UnsafeMutableRawPointer, UnsafeRawPointer) -> Int32
    typealias ProcessIsLive = (pid_t) -> Bool

    /// Call after the dedicated host has created its own WKWebsiteDataStore.
    /// This PID-only helper is retained for diagnostics; use `currentOwner`
    /// before registering a broker lease.
    static func currentPID(for dataStore: WKWebsiteDataStore,
                           bundleURL: URL = Bundle.main.bundleURL) throws -> pid_t {
        let image = try WebKitRuntimeImageAttestation.attestCurrentProcess(bundleURL: bundleURL)
        let storeAddress = Unmanaged.passUnretained(dataStore).toOpaque()
        return try resolve(storeAddress: storeAddress, verifiedImage: image)
    }

    /// Host-facing resolver for broker enrollment. NetworkProcess is an XPC
    /// service, so its PPID is recorded but is not required to equal the host.
    /// The authenticated host IPC binds the report to a profile; the broker
    /// must still attest the live NetworkProcess executable before granting
    /// any flow authority.
    static func currentOwner(for dataStore: WKWebsiteDataStore,
                             bundleURL: URL = Bundle.main.bundleURL) throws -> Owner {
        let image = try WebKitRuntimeImageAttestation.attestCurrentProcess(bundleURL: bundleURL)
        let storeAddress = Unmanaged.passUnretained(dataStore).toOpaque()
        return try resolveOwner(storeAddress: storeAddress,
                                verifiedImage: image)
    }

    /// Resolves and snapshots a NetworkProcess belonging to the current user.
    /// XPC launch does not provide a stable host-parent relationship; PPID is
    /// retained as evidence only. The second read rejects exit/PID-reuse races.
    /// Callers must bind the report through authenticated host IPC, attest the
    /// live code identity, and revalidate immediately before broker enrollment.
    static func resolveOwner(storeAddress: UnsafeRawPointer,
                             verifiedImage: WebKitRuntimeImageAttestation.VerifiedImage,
                             expectedUserID: uid_t = geteuid(),
                             openImage: ImageOpener = { path, flags in dlopen(path, flags) },
                             lookupSymbol: SymbolLookup = { handle, name in dlsym(handle, name) },
                             closeImage: ImageCloser = { handle in _ = dlclose(handle) },
                             callFunction: FunctionCall? = nil,
                             readSnapshot: (pid_t) -> ProcessSnapshot? = ProcessSnapshot.current) throws -> Owner {
        var firstSnapshot: ProcessSnapshot?
        let pid = try resolve(
            storeAddress: storeAddress,
            verifiedImage: verifiedImage,
            openImage: openImage,
            lookupSymbol: lookupSymbol,
            closeImage: closeImage,
            callFunction: callFunction,
            processIsLive: { candidate in
                guard let snapshot = readSnapshot(candidate), snapshot.isValid,
                      snapshot.pid == candidate else { return false }
                firstSnapshot = snapshot
                return true
            })
        guard let firstSnapshot,
              firstSnapshot.userID == expectedUserID,
              let secondSnapshot = readSnapshot(pid),
              secondSnapshot.isValid,
              secondSnapshot == firstSnapshot else {
            throw Failure.invalidProcessIdentity
        }
        return Owner(pid: pid,
                     startedAtSeconds: firstSnapshot.startedAtSeconds,
                     startedAtMicroseconds: firstSnapshot.startedAtMicroseconds,
                     userID: firstSnapshot.userID,
                     parentPID: firstSnapshot.parentPID)
    }

    /// Opens the exact already-loaded image with RTLD_NOLOAD and resolves the
    /// owned C API from that handle. Dependencies are injectable for offline
    /// tests; production uses dyld and checks that the PID still exists.
    static func resolve(storeAddress: UnsafeRawPointer,
                        verifiedImage: WebKitRuntimeImageAttestation.VerifiedImage,
                        openImage: ImageOpener = { path, flags in dlopen(path, flags) },
                        lookupSymbol: SymbolLookup = { handle, name in dlsym(handle, name) },
                        closeImage: ImageCloser = { handle in _ = dlclose(handle) },
                        callFunction: FunctionCall? = nil,
                        processIsLive: ProcessIsLive = isLive) throws -> pid_t {
        let flags = Int32(RTLD_NOW | RTLD_NOLOAD)
        guard let handle = openImage(verifiedImage.url.path, flags) else {
            throw Failure.imageNotLoaded
        }
        defer { closeImage(handle) }

        guard let symbol = lookupSymbol(handle, symbolName) else {
            throw Failure.symbolMissing
        }
        let pid: Int32
        if let callFunction {
            pid = callFunction(symbol, storeAddress)
        } else {
            let function = unsafeBitCast(symbol, to: PIDFunction.self)
            pid = function(storeAddress)
        }
        guard pid > 1, processIsLive(pid) else {
            throw Failure.invalidProcessIdentifier
        }
        return pid_t(pid)
    }

    private static func isLive(_ pid: pid_t) -> Bool {
        let result = kill(pid, 0)
        return result == 0 || errno == EPERM
    }
}
