import Foundation

struct ProfileNoteConflictError: LocalizedError {
    var errorDescription: String? {
        "Заметка уже изменена в другом окне. Твой черновик остался здесь; скопируй его перед закрытием и открой актуальную заметку заново."
    }
}

@MainActor
extension ProfileStore {
    /// Compare only the edited field under the metadata lock, so unrelated
    /// metadata changes do not discard a valid note draft.
    @discardableResult
    func updateNote(
        _ note: String,
        for profileID: UUID,
        expectedNote: String
    ) throws -> BrowserProfile {
        guard let normalized = BrowserProfile.normalizedNote(note),
              let expected = BrowserProfile.normalizedNote(expectedNote)
        else { throw NeAntikError.invalidProfile }
        return try mutateProfile(withID: profileID) { current in
            guard current.note == expected else {
                throw ProfileNoteConflictError()
            }
            current.note = normalized
        }
    }
}
