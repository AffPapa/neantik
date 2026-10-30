import Foundation
import Security

/// Internal broker authority, not a proof of an Apple process or WK store.
/// A random bearer capability selects exactly one immutable route. The signed
/// owner must validate the profile/child before registering it and revoke it
/// on configuration change, child exit or loss of its private control channel.
final class WebKitRelayAuthority: @unchecked Sendable {
    struct Scope: Equatable, Hashable, Sendable {
        let profileID: UUID
        let storeID: UUID
        let sessionID: UUID
        let revision: UInt64

        fileprivate var isValid: Bool {
            let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            return profileID != zero && storeID == profileID && sessionID != zero && revision > 0
        }
    }
    enum Route: Sendable {
        /// Direct is an explicit user configuration, never a proxy retry.
        case direct
        case proxy(kind: ProxyKind, upstream: ProxyRelayDestination, credentials: ProxyRelayCredentials?)
    }
    enum Failure: Error, Equatable { case invalidScope, duplicateProfile, unavailable, entropy, capacity, alreadyIssued }

    /// These credentials may cross only the verified child's private pipe.
    /// No Codable/logging/reflection path exposes them accidentally.
    struct Capability: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let scope: Scope
        fileprivate let id: UUID
        fileprivate let username: String
        fileprivate let password: String
        var description: String { "WebKitRelayCapability(<redacted>)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
        // Internal typed composition, never a public manager/MCP result.
        func withCredentials<T>(_ body: (String, String) throws -> T) rethrows -> T {
            try body(username, password)
        }
    }
    struct Permit: Sendable {
        let scope: Scope
        fileprivate let id: UUID
        let route: Route
    }
    private struct Entry {
        let capability: Capability
        let authorization: Data
        let route: Route
        var issued = false
    }
    static let maximumProfiles = 32
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var closed = false

    func register(scope: Scope, route: Route) throws {
        guard scope.isValid else { throw Failure.invalidScope }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw Failure.unavailable }
        guard entries[scope.profileID] == nil else { throw Failure.duplicateProfile }
        guard entries.count < Self.maximumProfiles else { throw Failure.capacity }
        var entropy = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else { throw Failure.entropy }
        let capability = Capability(scope: scope, id: UUID(), username: "wk-" + UUID().uuidString.lowercased(),
                                    password: Data(entropy).base64EncodedString())
        entries[scope.profileID] = Entry(capability: capability,
            authorization: Data((capability.username + ":" + capability.password).utf8), route: route)
    }

    /// One bootstrap per scope. Failed launches revoke rather than reissue.
    func issue(for scope: Scope) throws -> Capability {
        lock.lock(); defer { lock.unlock() }
        guard !closed, var entry = entries[scope.profileID], entry.capability.scope == scope else { throw Failure.unavailable }
        guard !entry.issued else { throw Failure.alreadyIssued }
        entry.issued = true; entries[scope.profileID] = entry
        return entry.capability
    }

    func authorize(_ supplied: Data?) -> Permit? {
        guard let supplied, supplied.count <= 256 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        // Bounded registry; compare complete credentials, not only a username.
        for entry in entries.values where entry.issued {
            guard supplied.count == entry.authorization.count else { continue }
            var difference: UInt8 = 0
            for (a, b) in zip(supplied, entry.authorization) { difference |= a ^ b }
            if difference == 0 {
                return Permit(scope: entry.capability.scope, id: entry.capability.id, route: entry.route)
            }
        }
        return nil
    }

    /// Fresh check immediately before credential writes and tunnel admission.
    func isCurrent(_ permit: Permit) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let entry = entries[permit.scope.profileID] else { return false }
        return entry.issued && entry.capability.id == permit.id && entry.capability.scope == permit.scope
    }

    @discardableResult func revoke(_ scope: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[scope.profileID]?.capability.scope == scope else { return false }
        entries.removeValue(forKey: scope.profileID)
        return true
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; entries.removeAll()
    }
}
