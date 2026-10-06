import Combine
import Foundation

struct UserProfileTemplate: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let folderID: UUID?
    let tags: [String]
    let startURL: String

    init(name: String, profile: BrowserProfile, folderID: UUID?) throws {
        guard let name = ProfileFolder.normalizedName(name),
              let tags = BrowserProfile.normalizedTags(profile.tags),
              Self.isSafeStartURL(profile.startURL)
        else { throw ManagerLibraryError.invalidTemplate }
        self.id = UUID()
        self.name = name
        self.folderID = folderID
        self.tags = tags
        self.startURL = profile.startURL
    }

    // A template is reusable metadata, not a place to retain URL credentials
    // or bearer tokens. Users can set a more specific URL in the new editor.
    static func isSafeStartURL(_ value: String) -> Bool {
        guard value.utf8.count <= BrowserProfile.maximumStartURLUTF8Bytes,
              BrowserLaunchBuilder.validatedStartURL(value) != nil,
              let components = URLComponents(string: value)
        else { return false }
        return components.user == nil && components.password == nil &&
            components.query == nil && components.fragment == nil
    }

    func makeProfile() -> BrowserProfile {
        BrowserProfile(name: name, tags: tags, startURL: startURL)
    }
}

struct SavedWorkspaceFilter: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let query: WorkspaceQueryState
    let search: String

    init(name: String, query: WorkspaceQueryState, search: String) throws {
        guard let name = ProfileFolder.normalizedName(name),
              search.utf8.count <= 4096, PersistedInlineText.isSafe(search)
        else { throw ManagerLibraryError.invalidDocument }
        id = UUID(); self.name = name; self.query = query; self.search = search
    }

    func resolved(folders: [ProfileFolder], tags: Set<ProfileTagID>) -> (query: WorkspaceQueryState, adjusted: Bool) {
        var value = query
        if let folderID = value.selectedFolderID, !folders.contains(where: { $0.id == folderID }) {
            value = value.selecting(folderFilter: .unfiled)
        }
        if let tag = value.tag, !tags.contains(tag) { value = value.selecting(tag: nil) }
        return (value, value != query)
    }
}

enum ManagerOperation: String, Codable, Sendable {
    case create, edit, move, archive, undo, launch, stop, template, filter, delete
    var title: String {
        switch self {
        case .create: "Создание"
        case .edit: "Изменение"
        case .move: "Перемещение"
        case .archive: "Архив"
        case .undo: "Отмена изменения"
        case .launch: "Запуск"
        case .stop: "Остановка"
        case .template: "Шаблон"
        case .filter: "Фильтр"
        case .delete: "Удаление"
        }
    }
}
enum ManagerOperationResult: String, Codable, Sendable {
    case succeeded, failed, cancelled, deferred, requested
    var title: String {
        switch self {
        case .requested: "Запрошено — проверь состояние профиля"
        case .succeeded: "Готово"
        case .failed: "Ошибка — проверь диагностику и повтори действие"
        case .cancelled: "Отменено"
        case .deferred: "Отложено — дождись завершения подготовки или снижения нагрузки"
        }
    }
}
struct ManagerOperationEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let operation: ManagerOperation
    let result: ManagerOperationResult
    init(_ operation: ManagerOperation, _ result: ManagerOperationResult) {
        id = UUID(); date = Date(); self.operation = operation; self.result = result
    }
}
struct ManagerLibraryDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var templates: [UserProfileTemplate] = []
    var filters: [SavedWorkspaceFilter] = []
    var events: [ManagerOperationEvent] = []
    static let maximumItems = 50
    static let maximumEvents = 200
    static let maximumBytes = 256 * 1024

    mutating func renameFilter(id: UUID, to proposedName: String) throws {
        guard let name = ProfileFolder.normalizedName(proposedName),
              let index = filters.firstIndex(where: { $0.id == id })
        else { throw ManagerLibraryError.invalidDocument }
        filters[index].name = name
    }

    func validate() throws {
        guard schemaVersion == 1,
              templates.count <= Self.maximumItems, filters.count <= Self.maximumItems,
              events.count <= Self.maximumEvents,
              Set(templates.map(\.id)).count == templates.count,
              Set(filters.map(\.id)).count == filters.count
        else { throw ManagerLibraryError.invalidDocument }
        for template in templates {
            guard ProfileFolder.normalizedName(template.name) == template.name,
                  BrowserProfile.normalizedTags(template.tags) == template.tags,
                  UserProfileTemplate.isSafeStartURL(template.startURL)
            else { throw ManagerLibraryError.invalidTemplate }
        }
        for filter in filters {
            guard ProfileFolder.normalizedName(filter.name) == filter.name,
                  filter.search.utf8.count <= 4096, PersistedInlineText.isSafe(filter.search),
                  (filter.query.tag?.rawValue.utf8.count ?? 0) <= BrowserProfile.maximumTagUTF8Bytes
            else { throw ManagerLibraryError.invalidDocument }
        }
    }
}
enum ManagerLibraryError: LocalizedError {
    case invalidDocument, invalidTemplate
    var errorDescription: String? {
        switch self {
        case .invalidDocument: "Локальная библиотека недоступна или достигнут лимит (50 шаблонов/фильтров). Проверь файл библиотеки; профили не изменены."
        case .invalidTemplate: "Шаблон не сохранён. Проверь имя, теги и стартовый URL: параметры, фрагмент и логин/пароль URL в шаблон не входят."
        }
    }
}

/// All disk work runs off MainActor. The existing metadata lock serializes
/// read-modify-write across manager processes, and publication follows commit.
actor ManagerLibraryRepository {
    let paths: AppPaths
    let beforeWrite: @Sendable () throws -> Void
    let afterWrite: @Sendable () throws -> Void
    init(paths: AppPaths, beforeWrite: @escaping @Sendable () throws -> Void = {}, afterWrite: @escaping @Sendable () throws -> Void = {}) {
        self.paths = paths; self.beforeWrite = beforeWrite; self.afterWrite = afterWrite
    }
    private var file: URL { paths.rootDirectory.appendingPathComponent("manager-library.json") }
    private func read() throws -> ManagerLibraryDocument {
        try paths.validatePrivateFile(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: ManagerLibraryDocument.maximumBytes + 1) ?? Data()
        guard data.count <= ManagerLibraryDocument.maximumBytes else { throw ManagerLibraryError.invalidDocument }
        let document = try JSONDecoder().decode(ManagerLibraryDocument.self, from: data)
        try document.validate()
        return document
    }
    func load() throws -> ManagerLibraryDocument {
        try paths.withProfilesMetadataGuard { try read() }
    }
    func update(_ change: @Sendable (inout ManagerLibraryDocument) throws -> Void) throws -> ManagerLibraryDocument {
        try paths.withProfilesMetadataGuard {
            try Task.checkCancellation()
            var document = try read()
            try change(&document)
            try document.validate()
            let data = try JSONEncoder().encode(document)
            guard data.count <= ManagerLibraryDocument.maximumBytes else { throw ManagerLibraryError.invalidDocument }
            try Task.checkCancellation()
            try beforeWrite()
            do {
                try paths.writePrivateFile(data, to: file)
                try afterWrite()
            } catch {
                // A post-rename failure can mean commit already succeeded.
                // Reconcile exact disk state before deciding what UI publishes.
                guard (try? read()) == document else { throw error }
            }
            return document
        }
    }
}

@MainActor
final class ManagerLibraryController: ObservableObject {
    @Published private(set) var document = ManagerLibraryDocument()
    @Published private(set) var isBusy = false
    @Published var error: String?
    private let repository: ManagerLibraryRepository
    init(paths: AppPaths) { repository = ManagerLibraryRepository(paths: paths) }
    func load() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { document = try await repository.load(); error = nil }
        catch { self.error = "Не удалось прочитать локальную библиотеку. Профили не изменены." }
    }
    func update(operation: ManagerOperation? = nil, _ change: @escaping @Sendable (inout ManagerLibraryDocument) throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            document = try await repository.update { document in
                try change(&document)
                if let operation {
                    document.events.append(.init(operation, .succeeded))
                    document.events = Array(document.events.suffix(ManagerLibraryDocument.maximumEvents))
                }
            }
            error = nil
        } catch {
            self.error = (error as? ManagerLibraryError)?.localizedDescription ?? "Не удалось сохранить библиотеку. Проверь свободное место и права доступа, затем повтори."
            if let operation { record(operation, .failed) }
        }
    }
    // Journal writes serialize through the actor and never publish older
    // library state over an in-flight UI operation. UI refreshes on opening.
    func record(_ operation: ManagerOperation, _ result: ManagerOperationResult) {
        let event = ManagerOperationEvent(operation, result)
        Task {
            do {
                _ = try await repository.update {
                    $0.events.append(event)
                    $0.events = Array($0.events.suffix(ManagerLibraryDocument.maximumEvents))
                }
            } catch {
                self.error = "Журнал операций недоступен. Проверь свободное место и права доступа."
            }
        }
    }
}
