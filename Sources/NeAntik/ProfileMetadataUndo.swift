import Foundation

/// Session-only, one-level undo. No secrets or browser/session fields are held.
struct ProfileMetadataUndo: Sendable {
    let folderOnly: Bool
    let profileID: UUID
    let revision: UInt64
    let organizationRevision: UUID?
    let name: String
    let tags: [String]
    let isArchived: Bool
    let folderID: UUID?

    init(before: BrowserProfile, after: BrowserProfile, folderID: UUID?, organizationRevision: UUID?, folderOnly: Bool = false) {
        self.folderOnly = folderOnly
        profileID = after.id; revision = after.revision
        self.organizationRevision = organizationRevision
        name = before.name; tags = before.tags; isArchived = before.isArchived
        self.folderID = folderID
    }
    static func editorPreservesSecrets(original: BrowserProfile?, passwordUpdate: ProxyPasswordUpdate) -> Bool {
        guard let original else { return false }
        return passwordUpdate == .keepExisting || (original.proxy == nil && passwordUpdate == .delete)
    }

    static func onlyAllowedFieldsChanged(before: BrowserProfile, after: BrowserProfile) -> Bool {
        var comparable = after
        comparable.name = before.name; comparable.tags = before.tags
        comparable.isArchived = before.isArchived
        comparable.revision = before.revision; comparable.updatedAt = before.updatedAt
        // Persisted ISO dates have second precision; these fields are never restored.
        comparable.createdAt = before.createdAt
        return comparable == before
    }
}
struct ProfileMetadataUndoConflict: LocalizedError {
    var errorDescription: String? {
        "Отмена недоступна: профиль или папки уже изменились. Обнови список и проверь последнее состояние; более новые правки сохранены."
    }
}
