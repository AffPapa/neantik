import Foundation

struct DeletedProfileCredentialCleanupSummary: Equatable, Sendable {
    let attemptedCount: Int
    let clearedCount: Int
    let failedCount: Int
    let skippedActiveCount: Int
    let skippedBecauseMetadataUntrusted: Bool
    let inspectionFailed: Bool
    let alreadyRan: Bool

    static let alreadyCompleted = DeletedProfileCredentialCleanupSummary(
        attemptedCount: 0,
        clearedCount: 0,
        failedCount: 0,
        skippedActiveCount: 0,
        skippedBecauseMetadataUntrusted: false,
        inspectionFailed: false,
        alreadyRan: true
    )
}

actor DeletedProfileCredentialCleanup {
    private let paths: AppPaths
    private let keychain: KeychainStore
    private let beforeCandidateRevalidation: @Sendable (UUID) -> Void
    private var hasRun = false

    init(
        paths: AppPaths,
        keychain: KeychainStore,
        beforeCandidateRevalidation: @escaping @Sendable (UUID) -> Void = {
            _ in
        }
    ) {
        self.paths = paths
        self.keychain = keychain
        self.beforeCandidateRevalidation = beforeCandidateRevalidation
    }

    func runOnce(
        metadataIsTrusted: Bool,
        excluding activeProfileIDs: Set<UUID>
    ) -> DeletedProfileCredentialCleanupSummary {
        guard !hasRun else {
            return .alreadyCompleted
        }
        hasRun = true
        guard metadataIsTrusted else {
            return DeletedProfileCredentialCleanupSummary(
                attemptedCount: 0,
                clearedCount: 0,
                failedCount: 0,
                skippedActiveCount: 0,
                skippedBecauseMetadataUntrusted: true,
                inspectionFailed: false,
                alreadyRan: false
            )
        }

        let profileIDs: [UUID]
        do {
            profileIDs = try paths.pendingCredentialCleanupProfileIDs()
        } catch {
            return DeletedProfileCredentialCleanupSummary(
                attemptedCount: 0,
                clearedCount: 0,
                failedCount: 0,
                skippedActiveCount: 0,
                skippedBecauseMetadataUntrusted: false,
                inspectionFailed: true,
                alreadyRan: false
            )
        }

        var attemptedCount = 0
        var clearedCount = 0
        var failedCount = 0
        var skippedActiveCount = 0
        for profileID in profileIDs {
            guard !activeProfileIDs.contains(profileID) else {
                skippedActiveCount += 1
                continue
            }
            var keychainAttempted = false
            var cleared = false
            beforeCandidateRevalidation(profileID)
            do {
                try paths.withProcessLockGuard(for: profileID) {
                    guard try paths.privateFileEntryKind(
                        paths.profileCredentialCleanupMarker(
                            for: profileID
                        )
                    ) == .regular,
                        try paths.privateFileEntryKind(
                            paths.profileDeletionTombstone(
                                for: profileID
                            )
                        ) == .regular,
                        try paths.privateFileEntryKind(
                            paths.profileDirectory(for: profileID)
                        ) == .missing
                    else {
                        return
                    }
                    keychainAttempted = true
                    try keychain.deleteProxyPassword(
                        profileID: profileID
                    )
                    try paths.removeCredentialCleanupMarker(
                        for: profileID
                    )
                    cleared = true
                }
                guard keychainAttempted else {
                    continue
                }
                attemptedCount += 1
                guard cleared else {
                    failedCount += 1
                    continue
                }
                clearedCount += 1
            } catch {
                if keychainAttempted {
                    attemptedCount += 1
                    failedCount += 1
                }
            }
        }
        return DeletedProfileCredentialCleanupSummary(
            attemptedCount: attemptedCount,
            clearedCount: clearedCount,
            failedCount: failedCount,
            skippedActiveCount: skippedActiveCount,
            skippedBecauseMetadataUntrusted: false,
            inspectionFailed: false,
            alreadyRan: false
        )
    }
}
