import Foundation

struct ProfileFilteredCountPresentation: Equatable, Sendable {
    let visibleCount: Int
    let totalCount: Int

    var title: String {
        visibleCount == totalCount
            ? "Профилей: \(totalCount)"
            : "Показано \(visibleCount) из \(totalCount)"
    }

    var announcement: String {
        visibleCount == totalCount
            ? "В списке \(totalCount) профилей"
            : "По текущим фильтрам показано \(visibleCount) из \(totalCount) профилей"
    }
}

enum ProfileListEmptyAction: Equatable, Sendable {
    case clearSearch
    case clearRouteFilter
    case showAllProfiles
    case createInCurrentFolder
    case resetAll
}

struct ProfileListEmptyStatePresentation: Equatable, Sendable {
    let title: String
    let message: String
    let systemImage: String
    let primaryAction: ProfileListEmptyAction
    let primaryTitle: String

    static func resolve(
        searchText: String,
        routeFilter: ProfileRouteFilter,
        scope: ProfileListScope,
        folderFilter: ProfileFolderFilter,
        hasTagFilter: Bool
    ) -> Self {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(
                title: "По запросу ничего не найдено",
                message: "Очисти поиск или уточни слова.",
                systemImage: "magnifyingglass",
                primaryAction: .clearSearch,
                primaryTitle: "Очистить поиск"
            )
        }
        if routeFilter != .all {
            return Self(
                title: "Нет профилей с таким подключением",
                message: "Покажи все типы подключения.",
                systemImage: "network.slash",
                primaryAction: .clearRouteFilter,
                primaryTitle: "Показать все подключения"
            )
        }
        if hasTagFilter {
            return Self(
                title: "Нет профилей с этим тегом",
                message: "Выбери другой тег или покажи все профили.",
                systemImage: "tag",
                primaryAction: .showAllProfiles,
                primaryTitle: "Показать все профили"
            )
        }
        switch folderFilter {
        case .folder:
            return Self(
                title: "В этой папке пока нет профилей",
                message: "Создай профиль сразу в выбранной папке.",
                systemImage: "folder",
                primaryAction: .createInCurrentFolder,
                primaryTitle: "Создать профиль"
            )
        case .unfiled:
            return Self(
                title: "Все профили разложены по папкам",
                message: "В разделе «Без папки» ничего не осталось.",
                systemImage: "tray",
                primaryAction: .showAllProfiles,
                primaryTitle: "Показать все профили"
            )
        case .all:
            break
        }
        switch scope {
        case .pinned:
            return Self(
                title: "Нет закреплённых профилей",
                message: "Закрепи важный профиль через меню его строки.",
                systemImage: "pin",
                primaryAction: .showAllProfiles,
                primaryTitle: "Показать все профили"
            )
        case .archived:
            return Self(
                title: "Архив пуст",
                message: "Архивированные профили появятся здесь.",
                systemImage: "archivebox",
                primaryAction: .showAllProfiles,
                primaryTitle: "Показать активные"
            )
        case .active:
            return Self(
                title: "Нет профилей с текущими фильтрами",
                message: "Сбрось фильтры и попробуй снова.",
                systemImage: "line.3.horizontal.decrease.circle",
                primaryAction: .resetAll,
                primaryTitle: "Сбросить фильтры"
            )
        }
    }
}
