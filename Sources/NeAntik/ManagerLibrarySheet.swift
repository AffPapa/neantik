import SwiftUI

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
    @FocusState private var nameFocused: Bool

    private func later(_ action: @escaping () -> Void) {
        guard !isPerforming else { return }
        isPerforming = true
        performAction(action)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Шаблоны, фильтры и журнал").font(.title2.bold())
            if let error = localError ?? library.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if library.isBusy { ProgressView("Чтение / сохранение…") }
            HStack {
                TextField("Название шаблона или фильтра", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                Button("Сохранить шаблон") {
                    guard let profile else { return }
                    do {
                        preview = try UserProfileTemplate(name: name, profile: profile, folderID: folderID)
                        localError = nil
                    } catch { localError = error.localizedDescription }
                }.disabled(profile == nil || name.isEmpty || library.isBusy)
                Button("Сохранить фильтр") {
                    do {
                        let filter = try SavedWorkspaceFilter(name: name, query: query, search: search)
                        Task { await library.update(operation: .filter) { $0.filters.append(filter) } }
                        localError = nil
                    } catch { localError = error.localizedDescription }
                }.disabled(name.isEmpty || library.isBusy)
            }
            TabView {
                List {
                    if library.document.templates.isEmpty { Text("Нет пользовательских шаблонов. Выбери профиль и задай название.") }
                    ForEach(library.document.templates) { template in
                        HStack {
                            Text(template.name).lineLimit(1)
                            Spacer()
                            Button("Состав / создать") { preview = template }
                            Button("Удалить") { Task { await library.update(operation: .template) { $0.templates.removeAll { $0.id == template.id } } } }
                        }
                    }
                }.tabItem { Text("Шаблоны") }
                List {
                    if library.document.filters.isEmpty { Text("Сохрани текущие область, папку, тег и поисковый запрос.") }
                    ForEach(library.document.filters) { filter in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(filter.name).lineLimit(1)
                                Text(filter.query.scope.title + " • " + (filter.search.isEmpty ? "Без поискового запроса" : filter.search)).font(.caption).lineLimit(1)
                            }
                            Spacer()
                            Button("Применить") { later { apply(filter) } }
                            Button("Переименовать") {
                                guard let newName = ProfileFolder.normalizedName(name) else { localError = "Введи новое название в поле сверху."; return }
                                Task { await library.update(operation: .filter) { document in
                                    if let index = document.filters.firstIndex(where: { $0.id == filter.id }) { document.filters[index].name = newName }
                                } }
                            }
                            Button("Удалить") { Task { await library.update(operation: .filter) { $0.filters.removeAll { $0.id == filter.id } } } }
                        }
                    }
                }.tabItem { Text("Фильтры") }
                VStack(alignment: .leading) {
                    Text("Последние 200 операций на этом Mac. Без имён профилей, адресов, IP и содержимого данных.").font(.caption)
                    List(library.document.events.reversed()) { event in
                        HStack {
                            Text(event.date, style: .time)
                            Text(event.operation.title)
                            Spacer()
                            Text(event.result.title).foregroundStyle(.secondary)
                        }.font(.callout)
                    }
                    Button("Очистить журнал") { Task { await library.update { $0.events = [] } } }
                }.tabItem { Text("Журнал") }
            }.disabled(library.isBusy)
            HStack {
                Text("Только локальные данные; до 50 шаблонов и 50 фильтров.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 760, height: 510)
        .task { await library.load(); nameFocused = true }
        .sheet(item: $preview) { template in
            VStack(alignment: .leading, spacing: 14) {
                Text(template.name).font(.title2.bold())
                Text("Папка: \(folders.first(where: { $0.id == template.folderID })?.name ?? "Без папки")")
                Text("Теги: \(template.tags.joined(separator: ", "))")
                Text("Стартовый URL: \(template.startURL)").textSelection(.enabled).lineLimit(4)
                Text("Новая identity. Cookies, BrowserData, заметки, прокси и пароли не копируются.").foregroundStyle(.secondary)
                HStack {
                    Button("Отмена", role: .cancel) { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if library.document.templates.contains(where: { $0.id == template.id }) {
                        Button("Создать профиль…") { preview = nil; later { create(template) } }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("Сохранить") {
                            preview = nil
                            Task { await library.update(operation: .template) { $0.templates.append(template) } }
                        }.keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(24).frame(width: 530).accessibilityHidden(true)
        }
    }
}
