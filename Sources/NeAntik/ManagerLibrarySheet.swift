import SwiftUI

private enum LibraryDeletionTarget {
    case template(UUID)
    case filter(UUID)
    case events

    var message: String {
        switch self {
        case .template: NSLocalizedString("page.073", tableName: "Pages", bundle: .main, value: "Выбранный шаблон будет удалён. Профили не изменятся.", comment: "")
        case .filter: NSLocalizedString("page.074", tableName: "Pages", bundle: .main, value: "Выбранный фильтр будет удалён. Профили не изменятся.", comment: "")
        case .events: NSLocalizedString("page.075", tableName: "Pages", bundle: .main, value: "Локальный журнал операций будет очищен. Профили не изменятся.", comment: "")
        }
    }
}

struct ManagerLibrarySheet: View {
    @ObservedObject var library: ManagerLibraryController
    let profile: BrowserProfile?
    let folderID: UUID?
    let folders: [ProfileFolder]
    let query: WorkspaceQueryState
    let search: String
    let create: (UserProfileTemplate) -> Void
    let apply: (SavedWorkspaceFilter) -> Void
    let performAction: (@escaping () -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isPerforming = false
    @State private var name = ""
    @State private var preview: UserProfileTemplate?
    @State private var localError: String?
    @State private var deletionTarget: LibraryDeletionTarget?
    @State private var renamingFilter: SavedWorkspaceFilter?
    @FocusState private var nameFocused: Bool

    private var availableTemplates: [UserProfileTemplate] {
        library.document.templates.filter { ($0.engine ?? .chromium).isAvailableInBuild }
    }

    private func later(_ action: @escaping () -> Void) {
        guard !isPerforming else { return }
        isPerforming = true
        performAction(action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(NSLocalizedString("page.076", tableName: "Pages", bundle: .main, value: "Шаблоны, фильтры и журнал", comment: "")).font(.title2.bold())
                Spacer()
                HelpLink(topic: .library)
            }
            Text(NSLocalizedString("page.077", tableName: "Pages", bundle: .main, value: "Шаблон берёт настройки выбранного профиля без паролей и данных сайтов. Фильтр сохраняет текущий поиск и область списка.", comment: ""))
                .font(.callout).foregroundStyle(.secondary)
            if let error = localError ?? library.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if library.isBusy { ProgressView(NSLocalizedString("page.078", tableName: "Pages", bundle: .main, value: "Чтение / сохранение…", comment: "")) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    creationControls
                }
                .frame(minWidth: 620)
                VStack(alignment: .leading, spacing: 8) {
                    creationControls
                }
            }
            TabView {
                List {
                    if availableTemplates.isEmpty { Text(NSLocalizedString("page.079", tableName: "Pages", bundle: .main, value: "Нет шаблонов для этого движка. Выбери профиль Chromium и задай название.", comment: "")) }
                    ForEach(availableTemplates) { template in
                        HStack {
                            Text(template.name).lineLimit(2).help(template.name)
                            Spacer()
                            Button(NSLocalizedString("page.080", tableName: "Pages", bundle: .main, value: "Состав / создать", comment: "")) { preview = template }
                            Button(NSLocalizedString("page.081", tableName: "Pages", bundle: .main, value: "Удалить", comment: "")) { deletionTarget = .template(template.id) }
                        }
                    }
                }.tabItem { Text(NSLocalizedString("page.082", tableName: "Pages", bundle: .main, value: "Шаблоны", comment: "")) }
                List {
                    if library.document.filters.isEmpty { Text(NSLocalizedString("page.083", tableName: "Pages", bundle: .main, value: "Сохрани текущие область, папку, тег и поисковый запрос.", comment: "")) }
                    ForEach(library.document.filters) { filter in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(filter.name).lineLimit(2).help(filter.name)
                                Text(NSLocalizedString(filter.query.scope.title, tableName: "Pages", bundle: .main, value: filter.query.scope.title, comment: "") + " • " + (filter.search.isEmpty ? NSLocalizedString("page.084", tableName: "Pages", bundle: .main, value: "Без поискового запроса", comment: "") : filter.search)).font(.caption).lineLimit(1).help(filter.search.isEmpty ? NSLocalizedString("page.084", tableName: "Pages", bundle: .main, value: "Без поискового запроса", comment: "") : filter.search)
                            }
                            Spacer()
                            Button(NSLocalizedString("page.085", tableName: "Pages", bundle: .main, value: "Применить", comment: "")) { later { apply(filter) } }
                            Button(NSLocalizedString("page.086", tableName: "Pages", bundle: .main, value: "Переименовать", comment: "")) {
                                renamingFilter = filter
                            }
                            Button(NSLocalizedString("page.081", tableName: "Pages", bundle: .main, value: "Удалить", comment: "")) { deletionTarget = .filter(filter.id) }
                        }
                    }
                }.tabItem { Text(NSLocalizedString("page.087", tableName: "Pages", bundle: .main, value: "Фильтры", comment: "")) }
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("page.088", tableName: "Pages", bundle: .main, value: "Последние 200 операций на этом Mac. Без имён профилей, адресов, IP и содержимого данных.", comment: "")).font(.caption)
                    List(library.document.events.reversed()) { event in
                        HStack {
                            Text(event.date, style: .time)
                            Text(NSLocalizedString(event.operation.title, tableName: "Pages", bundle: .main, value: event.operation.title, comment: ""))
                            Spacer()
                            Text(NSLocalizedString(event.result.title, tableName: "Pages", bundle: .main, value: event.result.title, comment: "")).foregroundStyle(.secondary)
                        }.font(.callout)
                    }
                    Button(NSLocalizedString("page.089", tableName: "Pages", bundle: .main, value: "Очистить журнал", comment: "")) { deletionTarget = .events }
                        .disabled(library.document.events.isEmpty)
                }.tabItem { Text(NSLocalizedString("page.090", tableName: "Pages", bundle: .main, value: "Журнал", comment: "")) }
            }.disabled(library.isBusy)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(NSLocalizedString("page.091", tableName: "Pages", bundle: .main, value: "Только локальные данные; до 50 шаблонов и 50 фильтров.", comment: "")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    closeButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("page.091", tableName: "Pages", bundle: .main, value: "Только локальные данные; до 50 шаблонов и 50 фильтров.", comment: "")).font(.caption).foregroundStyle(.secondary)
                    closeButton
                }
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 680, maxWidth: 820, minHeight: 400, idealHeight: 520, maxHeight: 680)
        .task { await library.load(); nameFocused = true }
        .alert(NSLocalizedString("page.092", tableName: "Pages", bundle: .main, value: "Подтвердить удаление", comment: ""), isPresented: Binding(
            get: { deletionTarget != nil },
            set: { if !$0 { deletionTarget = nil } }
        )) {
            Button(NSLocalizedString("page.081", tableName: "Pages", bundle: .main, value: "Удалить", comment: ""), role: .destructive) { commitDeletion() }
            Button(NSLocalizedString("page.093", tableName: "Pages", bundle: .main, value: "Отмена", comment: ""), role: .cancel) { deletionTarget = nil }
        } message: {
            Text(deletionTarget?.message ?? "")
        }
        .sheet(item: $renamingFilter) { filter in
            FilterRenameSheet(initialName: filter.name) { proposedName in
                renamingFilter = nil
                Task {
                    await library.update(operation: .filter) { document in
                        try document.renameFilter(id: filter.id, to: proposedName)
                    }
                }
            }
        }
        .sheet(item: $preview) { template in
            VStack(alignment: .leading, spacing: 14) {
                Text(template.name).font(.title2.bold())
                Text(String(format: NSLocalizedString("page.folder", tableName: "Pages", bundle: .main, value: "Папка: %@", comment: ""), folders.first(where: { $0.id == template.folderID })?.name ?? NSLocalizedString("page.unfiled", tableName: "Pages", bundle: .main, value: "Без папки", comment: "")))
                Text(String(format: NSLocalizedString("page.tags", tableName: "Pages", bundle: .main, value: "Теги: %@", comment: ""), template.tags.joined(separator: ", ")))
                Text(String(format: NSLocalizedString("page.096", tableName: "Pages", bundle: .main, value: "Стартовый URL: %@", comment: ""), String(describing: template.startURL))).textSelection(.enabled).lineLimit(4)
                Text(NSLocalizedString("page.097", tableName: "Pages", bundle: .main, value: "Новая identity. Cookies, BrowserData, заметки, прокси и пароли не копируются.", comment: "")).foregroundStyle(.secondary)
                HStack {
                    Button(NSLocalizedString("page.093", tableName: "Pages", bundle: .main, value: "Отмена", comment: ""), role: .cancel) { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if availableTemplates.contains(where: { $0.id == template.id }) {
                        Button(NSLocalizedString("page.098", tableName: "Pages", bundle: .main, value: "Создать профиль…", comment: "")) { preview = nil; later { create(template) } }.keyboardShortcut(.defaultAction)
                    } else {
                        Button(NSLocalizedString("page.099", tableName: "Pages", bundle: .main, value: "Сохранить", comment: "")) {
                            preview = nil
                            Task { await library.update(operation: .template) { $0.templates.append(template) } }
                        }.keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(24).frame(width: 530)
        }
    }

    private var creationControls: some View {
        Group {
            TextField(NSLocalizedString("page.100", tableName: "Pages", bundle: .main, value: "Название шаблона или фильтра", comment: ""), text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
            Button(NSLocalizedString("page.101", tableName: "Pages", bundle: .main, value: "Сохранить шаблон", comment: "")) {
                guard let profile else { return }
                do {
                    preview = try UserProfileTemplate(name: name, profile: profile, folderID: folderID)
                    localError = nil
                } catch { localError = error.localizedDescription }
            }.disabled(profile == nil || profile?.engine.isAvailableInBuild != true || name.isEmpty || library.isBusy)
            Button(NSLocalizedString("page.102", tableName: "Pages", bundle: .main, value: "Сохранить фильтр", comment: "")) {
                do {
                    let filter = try SavedWorkspaceFilter(name: name, query: query, search: search)
                    Task { await library.update(operation: .filter) { $0.filters.append(filter) } }
                    localError = nil
                } catch { localError = error.localizedDescription }
            }.disabled(name.isEmpty || library.isBusy)
        }
    }

    private var closeButton: some View {
        Button(NSLocalizedString("page.021", tableName: "Pages", bundle: .main, value: "Закрыть", comment: ""), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
    }

    private func commitDeletion() {
        guard let target = deletionTarget else { return }
        deletionTarget = nil
        switch target {
        case .template(let id):
            Task { await library.update(operation: .template) { $0.templates.removeAll { $0.id == id } } }
        case .filter(let id):
            Task { await library.update(operation: .filter) { $0.filters.removeAll { $0.id == id } } }
        case .events:
            Task { await library.update { $0.events = [] } }
        }
    }
}

private struct FilterRenameSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(initialName: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("page.103", tableName: "Pages", bundle: .main, value: "Переименовать фильтр", comment: "")).font(.title2.bold())
            TextField(NSLocalizedString("page.104", tableName: "Pages", bundle: .main, value: "Название фильтра", comment: ""), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            Text(NSLocalizedString("page.105", tableName: "Pages", bundle: .main, value: "Изменится только название выбранного фильтра.", comment: ""))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(NSLocalizedString("page.093", tableName: "Pages", bundle: .main, value: "Отмена", comment: ""), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("page.099", tableName: "Pages", bundle: .main, value: "Сохранить", comment: "")) { onSave(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ProfileFolder.normalizedName(name) == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 460, maxWidth: 540)
        .onAppear { nameFocused = true }
    }
}
