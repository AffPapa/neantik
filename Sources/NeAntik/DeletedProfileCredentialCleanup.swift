import Foundation

struct DeletedProfileCredentialCleanupSummary: Equatable, Sendable {
    let attemptedCount: Int
    let clearedCount: Int
    let failedCount: Int
    let skippedActiveCount: Int
    let skippedBecauseMetadataUntrusted: Bool
    let inspectionFailed: Bool
    let alreadyRan: Bool
    // Aggregate classifications only: no profile IDs, Keychain services or data.
    var keychainCategories: Set<KeychainPurgeCategory> = []
    var markerFailure: Bool = false

    var userMessage: String {
        var messages: [String] = []
        if skippedBecauseMetadataUntrusted {
            messages.append(NSLocalizedString("cleanup.metadata", tableName: "Errors", bundle: .main, value: "Не удалось проверить данные профилей, поэтому очистка учётных данных не выполнялась.", comment: "Credential cleanup metadata unavailable"))
        }
        if inspectionFailed {
            messages.append(NSLocalizedString("cleanup.inspection", tableName: "Errors", bundle: .main, value: "Не удалось безопасно проверить некоторые служебные данные очистки.", comment: "Credential cleanup inspection"))
        }
        if keychainCategories.contains(.accessDenied) {
            messages.append(NSLocalizedString("cleanup.access", tableName: "Errors", bundle: .main, value: "macOS не подтвердила доступ к некоторым записям Связки ключей.", comment: "Credential cleanup access"))
        }
        if keychainCategories.contains(.unavailable) {
            messages.append(NSLocalizedString("cleanup.unavailable", tableName: "Errors", bundle: .main, value: "Операция со Связкой ключей сейчас недоступна.", comment: "Credential cleanup unavailable"))
        }
        if keychainCategories.contains(.other) {
            messages.append(NSLocalizedString("cleanup.other", tableName: "Errors", bundle: .main, value: "Не удалось завершить операцию со Связкой ключей.", comment: "Credential cleanup other failure"))
        }
        if markerFailure {
            messages.append(NSLocalizedString("cleanup.marker", tableName: "Errors", bundle: .main, value: "Не удалось обновить служебную отметку очистки.", comment: "Credential cleanup marker"))
        }
        if messages.isEmpty {
            messages.append(NSLocalizedString("cleanup.generic", tableName: "Errors", bundle: .main, value: "Не удалось подтвердить завершение очистки сохранённых паролей прокси.", comment: "Credential cleanup generic"))
        }
        messages.append(NSLocalizedString("cleanup.nextStart", tableName: "Errors", bundle: .main, value: "NeAntik безопасно повторит проверку при следующем запуске. Если сообщение сохранится, обратись в поддержку.", comment: "Credential cleanup next step"))
        return messages.joined(separator: " ")
    }

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
    private let beforeMarkerRemoval: @Sendable (UUID) throws -> Void
    private var hasRun = false
    private var lastSummary: DeletedProfileCredentialCleanupSummary?

    init(
        paths: AppPaths,
        keychain: KeychainStore,
        beforeCandidateRevalidation: @escaping @Sendable (UUID) -> Void = {
            _ in
        },
        beforeMarkerRemoval: @escaping @Sendable (UUID) throws -> Void = { _ in }
    ) {
        self.paths = paths
        self.keychain = keychain
        self.beforeCandidateRevalidation = beforeCandidateRevalidation
        self.beforeMarkerRemoval = beforeMarkerRemoval
    }

    func runOnce(
        metadataIsTrusted: Bool,
        excluding activeProfileIDs: Set<UUID>
    ) -> DeletedProfileCredentialCleanupSummary {
        guard !hasRun else {
            return .alreadyCompleted
        }
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
        hasRun = true

        // A bulk import holds this lease from the first journal write until
        // metadata commit or rollback. Startup cleanup therefore cannot race
        // a still-in-flight import from another process.
        let bulkImportLease: PrivateFileGuardLease
        do {
            bulkImportLease = try paths.acquireBulkCredentialImportGuard()
        } catch {
            return record(DeletedProfileCredentialCleanupSummary(
                attemptedCount: 0,
                clearedCount: 0,
                failedCount: 0,
                skippedActiveCount: 0,
                skippedBecauseMetadataUntrusted: false,
                inspectionFailed: true,
                alreadyRan: false
            ))
        }
        defer { bulkImportLease.release() }

        let profileIDs: [UUID]
        let stagedProfileIDs: [UUID]
        do {
            profileIDs = try paths.pendingCredentialCleanupProfileIDs()
            stagedProfileIDs = try paths.pendingCredentialStagingProfileIDs()
        } catch {
            return record(DeletedProfileCredentialCleanupSummary(
                attemptedCount: 0,
                clearedCount: 0,
                failedCount: 0,
                skippedActiveCount: 0,
                skippedBecauseMetadataUntrusted: false,
                inspectionFailed: true,
                alreadyRan: false
            ))
        }

        var attemptedCount = 0
        var clearedCount = 0
        var failedCount = 0
        var skippedActiveCount = 0
        var inspectionFailed = false
        var keychainCategories = Set<KeychainPurgeCategory>()
        var markerFailure = false

        // Staging markers differ from deletion markers: they are written
        // before Keychain work and require no deletion tombstone. If profile
        // metadata is now active, the import committed and only the journal is
        // stale. Otherwise a missing profile directory proves the staged
        // secret is an orphan and may be removed safely.
        for profileID in stagedProfileIDs {
            var keychainAttempted = false
            var keychainCompleted = false
            var activeMarkerRemovalAttempted = false
            var cleared = false
            do {
                try paths.withProcessLockGuard(for: profileID) {
                    let marker = paths.profileCredentialStagingMarker(
                        for: profileID
                    )
                    guard try paths.privateFileEntryKind(marker) == .regular
                    else {
                        inspectionFailed = true
                        return
                    }
                    if activeProfileIDs.contains(profileID) {
                        activeMarkerRemovalAttempted = true
                        try beforeMarkerRemoval(profileID)
                        try paths.removeCredentialStagingMarker(
                            for: profileID
                        )
                        skippedActiveCount += 1
                        return
                    }
                    guard try paths.privateFileEntryKind(
                        paths.profileDirectory(for: profileID)
                    ) == .missing else {
                        inspectionFailed = true
                        return
                    }
                    keychainAttempted = true
                    try keychain.deleteProxyPassword(profileID: profileID)
                    keychainCompleted = true
                    try beforeMarkerRemoval(profileID)
                    try paths.removeCredentialStagingMarker(for: profileID)
                    cleared = true
                }
                guard keychainAttempted else { continue }
                attemptedCount += 1
                if cleared {
                    clearedCount += 1
                } else {
                    failedCount += 1
                }
            } catch {
                if keychainAttempted {
                    attemptedCount += 1
                    failedCount += 1
                    if keychainCompleted { markerFailure = true }
                    else { keychainCategories.formUnion((error as? KeychainCredentialPurgeError)?.categories ?? [.other]) }
                } else {
                    if activeMarkerRemovalAttempted { markerFailure = true }
                    else { inspectionFailed = true }
                }
            }
        }

        for profileID in profileIDs {
            guard !activeProfileIDs.contains(profileID) else {
                skippedActiveCount += 1
                continue
            }
            var keychainAttempted = false
            var keychainCompleted = false
            var cleared = false
            beforeCandidateRevalidation(profileID)
            do {
                try paths.withProcessLockGuard(for: profileID) {
                    let markerKind = try paths.privateFileEntryKind(
                        paths.profileCredentialCleanupMarker(
                            for: profileID
                        )
                    )
                    guard markerKind != .missing else {
                        return
                    }
                    guard markerKind == .regular,
                          try paths.privateFileEntryKind(
                              paths.profileDeletionTombstone(
                                  for: profileID
                              )
                          ) == .regular,
                          try paths.privateFileEntryKind(
                              paths.profileDirectory(for: profileID)
                          ) == .missing
                    else {
                        inspectionFailed = true
                        return
                    }
                    keychainAttempted = true
                    try keychain.deleteProxyPassword(
                        profileID: profileID
                    )
                    keychainCompleted = true
                    try beforeMarkerRemoval(profileID)
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
                    if keychainCompleted { markerFailure = true }
                    else { keychainCategories.formUnion((error as? KeychainCredentialPurgeError)?.categories ?? [.other]) }
                } else {
                    inspectionFailed = true
                }
            }
        }
        return record(DeletedProfileCredentialCleanupSummary(
            attemptedCount: attemptedCount,
            clearedCount: clearedCount,
            failedCount: failedCount,
            skippedActiveCount: skippedActiveCount,
            skippedBecauseMetadataUntrusted: false,
            inspectionFailed: inspectionFailed,
            alreadyRan: false,
            keychainCategories: keychainCategories,
            markerFailure: markerFailure
        ))
    }

    /// Re-deliver the sanitized result without touching Keychain again.
    func lastOutcome() -> DeletedProfileCredentialCleanupSummary? { lastSummary }

    /// Acknowledging presentation does not grant another cleanup attempt.
    func acknowledgeOutcome() { lastSummary = nil }

    private func record(_ summary: DeletedProfileCredentialCleanupSummary) -> DeletedProfileCredentialCleanupSummary {
        lastSummary = summary
        return summary
    }
}
