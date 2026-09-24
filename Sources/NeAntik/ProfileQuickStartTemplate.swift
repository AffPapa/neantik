import Foundation

enum ProfileQuickStartTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank
    case work
    case testing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Пустой"
        case .work: "Работа"
        case .testing: "Тестирование"
        }
    }

    var suggestedName: String? {
        switch self {
        case .blank: nil
        case .work: "Работа"
        case .testing: "Тестирование"
        }
    }

    var suggestedTag: String? {
        switch self {
        case .blank: nil
        case .work: "работа"
        case .testing: "тест"
        }
    }

    func draft(
        name: String,
        tags: [String],
        replacing previous: Self = .blank,
        replacingGeneratedName: Bool = false,
        replacingGeneratedTag: Bool = false
    ) -> (name: String, tags: [String]) {
        var nextName = name
        var nextTags = tags
        if replacingGeneratedName,
           let oldName = previous.suggestedName,
           name == oldName
        {
            nextName = ""
        }
        if replacingGeneratedTag, let oldTag = previous.suggestedTag {
            nextTags.removeAll(where: {
                $0.localizedCaseInsensitiveCompare(oldTag) == .orderedSame
            })
        }
        guard let suggestedName, let suggestedTag else {
            return (nextName, nextTags)
        }
        if nextTags.contains(where: {
            $0.localizedCaseInsensitiveCompare(suggestedTag) == .orderedSame
        }) == false {
            nextTags.append(suggestedTag)
        }
        if nextName.isEmpty { nextName = suggestedName }
        return (nextName, nextTags)
    }
}
