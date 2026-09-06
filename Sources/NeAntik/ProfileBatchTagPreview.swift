import Foundation

/// Metadata-only preview. The store still revalidates the entire transaction.
struct ProfileBatchTagPreview: Equatable {
    let total: Int
    let matching: Int
    let affected: Int
    let blocked: Int
    let valid: Bool

    var canApply: Bool { valid && affected > 0 && blocked == 0 }

    var message: String {
        guard valid else { return ProfileBatchMutationError.invalidTag.localizedDescription }
        if blocked > 0 {
            return "Лимит тегов достигнут в \(blocked) профилях. Ничего не будет изменено."
        }
        guard affected > 0 else { return "Этот тег уже в нужном состоянии. Изменений нет." }
        return "Изменится: \(affected) из \(total) · без изменений: \(total - affected)"
    }

    static func resolve(profiles: [BrowserProfile], tag: String, adding: Bool) -> Self {
        guard let clean = BrowserProfile.normalizedTags([tag])?.first else {
            return Self(total: profiles.count, matching: 0, affected: 0, blocked: 0, valid: false)
        }
        let id = ProfileTagID(displayName: clean)
        var matching = 0
        var blocked = 0
        for profile in profiles {
            let contains = profile.tags.contains { ProfileTagID(displayName: $0) == id }
            if contains { matching += 1 }
            if adding && !contains && profile.tags.count >= BrowserProfile.maximumTagCount {
                blocked += 1
            }
        }
        return Self(total: profiles.count, matching: matching,
                    affected: adding ? profiles.count - matching : matching,
                    blocked: blocked, valid: true)
    }

    static func suggestions(profiles: [BrowserProfile], library: [String], adding: Bool) -> [String] {
        ProfileTagEditorModel.availableSuggestions(
            adding ? library : profiles.flatMap(\.tags), excluding: []
        )
    }

    static func visibleSuggestions(
        profiles: [BrowserProfile], library: [String], adding: Bool, query: String
    ) -> [String] {
        Array(ProfileTagEditorModel.filteredSuggestions(
            suggestions(profiles: profiles, library: library, adding: adding),
            matching: query
        ).prefix(8))
    }
}
