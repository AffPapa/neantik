import Foundation

/// Shared backup-before-write mechanics, not document schemas or recovery policy.
struct RecoverableDocumentStorage<Value> {
    enum EntryPolicy { case profiles, organization }
    let paths: AppPaths
    let current: URL
    let backup: URL
    let maximumBytes: Int
    let policy: EntryPolicy
    let decode: (Data) throws -> Value

    private func exists(_ url: URL) throws -> Bool {
        if policy == .profiles {
            return FileManager.default.fileExists(atPath: url.path)
        }
        switch try paths.privateFileEntryKind(url) {
        case .missing: return false
        case .regular: return true
        case .unsafe: throw POSIXError(.EFTYPE)
        }
    }

    func persist(
        _ data: Data, synchronize: Bool,
        missingBackup: () throws -> Data
    ) throws {
        let previous: Data
        if synchronize {
            previous = data
        } else if try exists(current) {
            try paths.validatePrivateFile(current)
            previous = try paths.readPrivateFile(current, maximumBytes: maximumBytes)
            _ = try decode(previous)
        } else {
            previous = try missingBackup()
        }
        try paths.writePrivateFile(previous, to: backup)
        try paths.writePrivateFile(data, to: current)
    }

    func ensureSnapshot() throws {
        guard try exists(current) else { return }
        if try exists(backup) {
            try paths.validatePrivateFile(backup)
            return
        }
        if policy == .profiles { try paths.validatePrivateFile(current) }
        let data = try paths.readPrivateFile(current, maximumBytes: maximumBytes)
        // Profiles snapshots historically preserve raw bytes; organization
        // snapshots require a decodable document. Do not silently unify them.
        if policy == .organization { _ = try decode(data) }
        try paths.writePrivateFile(data, to: backup)
    }

    func restore(_ data: Data, preserving rejected: Data, prefix: String) throws -> URL? {
        let rejectedURL: URL?
        if ProfileRecoveryRetention.shouldPreserveRejectedFile(byteCount: rejected.count) {
            let url = paths.profilesRecoveryDirectory.appendingPathComponent(
                "\(prefix)-rejected-\(UUID().uuidString).json"
            )
            try paths.writePrivateFile(rejected, to: url)
            rejectedURL = url
        } else { rejectedURL = nil }
        try paths.writePrivateFile(data, to: current)
        try? ProfileRecoveryRetention.prune(
            directory: paths.profilesRecoveryDirectory, preserving: rejectedURL
        )
        return rejectedURL
    }
}
