import Foundation

struct ProfileFolder: Codable, Identifiable, Equatable, Sendable {
    static let maximumNameLength = 64
    static let maximumNameUTF8Bytes = 2 * 1_024

    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func normalizedName(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean.count <= maximumNameLength,
              clean.utf8.count <= maximumNameUTF8Bytes,
              PersistedInlineText.isSafe(clean)
        else {
            return nil
        }
        return clean
    }

    static func comparisonKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func areInIncreasingOrder(
        _ lhs: ProfileFolder,
        _ rhs: ProfileFolder
    ) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct ProfileFolderAssignment: Codable, Equatable, Sendable {
    let profileID: UUID
    let folderID: UUID
}

struct ProfileOrganizationDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var folders: [ProfileFolder]
    var assignments: [ProfileFolderAssignment]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        folders: [ProfileFolder] = [],
        assignments: [ProfileFolderAssignment] = []
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.assignments = assignments
    }

    init(state: ProfileOrganizationState) {
        schemaVersion = Self.currentSchemaVersion
        folders = state.folders.sorted(by: ProfileFolder.areInIncreasingOrder)
        assignments = state.assignmentsByProfileID
            .map {
                ProfileFolderAssignment(
                    profileID: $0.key,
                    folderID: $0.value
                )
            }
            .sorted {
                if $0.profileID != $1.profileID {
                    return $0.profileID.uuidString < $1.profileID.uuidString
                }
                return $0.folderID.uuidString < $1.folderID.uuidString
            }
    }

    func validatedState(
        knownProfileIDs: Set<UUID>
    ) throws -> (state: ProfileOrganizationState, changed: Bool) {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProfileOrganizationDocumentError.unsupportedSchema
        }

        var folderIDs = Set<UUID>()
        var folderNameKeys = Set<String>()
        var cleanFolders: [ProfileFolder] = []
        var changed = false
        for var folder in folders {
            guard folderIDs.insert(folder.id).inserted,
                  let cleanName = ProfileFolder.normalizedName(folder.name)
            else {
                throw ProfileOrganizationDocumentError.invalidFolder
            }
            let nameKey = ProfileFolder.comparisonKey(cleanName)
            guard folderNameKeys.insert(nameKey).inserted else {
                throw ProfileOrganizationDocumentError.duplicateFolderName
            }
            if folder.name != cleanName {
                folder.name = cleanName
                changed = true
            }
            cleanFolders.append(folder)
        }
        let sortedFolders = cleanFolders.sorted(
            by: ProfileFolder.areInIncreasingOrder
        )
        if sortedFolders != cleanFolders {
            changed = true
        }

        var assignmentsByProfileID: [UUID: UUID] = [:]
        for assignment in assignments {
            guard assignmentsByProfileID[assignment.profileID] == nil else {
                throw ProfileOrganizationDocumentError.duplicateAssignment
            }
            guard knownProfileIDs.contains(assignment.profileID),
                  folderIDs.contains(assignment.folderID)
            else {
                changed = true
                continue
            }
            assignmentsByProfileID[assignment.profileID] = assignment.folderID
        }

        let state = ProfileOrganizationState(
            folders: sortedFolders,
            assignmentsByProfileID: assignmentsByProfileID
        )
        if ProfileOrganizationDocument(state: state) != self {
            changed = true
        }
        return (state, changed)
    }
}

struct ProfileOrganizationState: Equatable, Sendable {
    static let empty = ProfileOrganizationState()

    private(set) var folders: [ProfileFolder]
    fileprivate(set) var assignmentsByProfileID: [UUID: UUID]

    init(
        folders: [ProfileFolder] = [],
        assignmentsByProfileID: [UUID: UUID] = [:]
    ) {
        self.folders = folders.sorted(by: ProfileFolder.areInIncreasingOrder)
        self.assignmentsByProfileID = assignmentsByProfileID
    }

    func folder(withID id: UUID?) -> ProfileFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    func folderID(forProfileID profileID: UUID) -> UUID? {
        assignmentsByProfileID[profileID]
    }

    func profileIDs(inFolderID folderID: UUID) -> [UUID] {
        assignmentsByProfileID.compactMap { profileID, assignedFolderID in
            assignedFolderID == folderID ? profileID : nil
        }.sorted { $0.uuidString < $1.uuidString }
    }

    mutating func addFolder(_ folder: ProfileFolder) {
        folders.append(folder)
        folders.sort(by: ProfileFolder.areInIncreasingOrder)
    }

    mutating func replaceFolder(_ folder: ProfileFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id })
        else {
            return
        }
        folders[index] = folder
        folders.sort(by: ProfileFolder.areInIncreasingOrder)
    }

    mutating func removeFolder(withID folderID: UUID) -> [UUID] {
        let affectedProfileIDs = profileIDs(inFolderID: folderID)
        folders.removeAll { $0.id == folderID }
        for profileID in affectedProfileIDs {
            assignmentsByProfileID.removeValue(forKey: profileID)
        }
        return affectedProfileIDs
    }

    mutating func assign(
        profileIDs: Set<UUID>,
        toFolderID folderID: UUID?
    ) {
        for profileID in profileIDs {
            assignmentsByProfileID[profileID] = folderID
        }
    }
}

enum ProfileOrganizationError: LocalizedError, Equatable {
    case invalidFolderName
    case duplicateFolderName
    case folderNotFound
    case profileNotFound
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFolderName:
            "Проверь название папки: от 1 до \(ProfileFolder.maximumNameLength) символов без переносов строк."
        case .duplicateFolderName:
            "Папка с таким именем уже существует."
        case .folderNotFound:
            "Папка уже удалена или недоступна. Профили не изменены."
        case .profileNotFound:
            "Один из профилей уже удалён. Папка не изменена."
        case .storageUnavailable:
            "Папки временно недоступны. Профили и данные браузеров не изменены."
        }
    }
}

private enum ProfileOrganizationDocumentError: LocalizedError {
    case unsupportedSchema
    case invalidFolder
    case duplicateFolderName
    case duplicateAssignment

    var errorDescription: String? {
        "Файл папок имеет неподдерживаемый или повреждённый формат."
    }
}
