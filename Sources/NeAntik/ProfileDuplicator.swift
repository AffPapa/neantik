import Foundation

enum ProfileDuplicator {
    @MainActor
    static func saveCopy(
        sourceProfileID: UUID,
        expectedSourceRevision: UInt64,
        options: ProfileDuplicationOptions,
        store: ProfileStore,
        keychain: KeychainStore
    ) throws -> BrowserProfile {
        guard let source = store.profile(withID: sourceProfileID) else {
            throw BrowserProfileDeletedError()
        }
        try ProfileDuplicationPolicy.requireCurrentSource(
            source,
            expectedRevision: expectedSourceRevision
        )
        let copy = try ProfileDuplicationPolicy.makeProfile(
            from: source,
            options: options
        )
        let password = ProfileDuplicationPolicy.shouldCopyProxyPassword(
            source: source,
            options: options
        ) ? try keychain.proxyPassword(profileID: source.id) : nil
        return try store.upsert(
            copy,
            toFolderID: options.destinationFolderID
        ) { saved in
            if let password, !password.isEmpty {
                try keychain.saveProxyPassword(password, profileID: saved.id)
            }
        }
    }
}
