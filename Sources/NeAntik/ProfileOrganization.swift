import Foundation

struct ProfileFolder: Codable, Identifiable, Equatable, Sendable {
    static let maximumNameLength = 64
    static let maximumNameUTF8Bytes = 2 * 1_024

    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var parentFolderID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        parentFolderID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentFolderID = parentFolderID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, parentFolderID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        // Schema v1 folder rows have no parent. They remain root folders.
        parentFolderID = try values.decodeIfPresent(UUID.self, forKey: .parentFolderID)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(parentFolderID, forKey: .parentFolderID)
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
    static let legacySchemaVersion = 1
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var folders: [ProfileFolder]
    var assignments: [ProfileFolderAssignment]
    var mutationRevision: UUID?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        folders: [ProfileFolder] = [],
        assignments: [ProfileFolderAssignment] = [],
        mutationRevision: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.assignments = assignments
        self.mutationRevision = mutationRevision
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, folders, assignments, mutationRevision
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard (Self.legacySchemaVersion...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw ProfileOrganizationDocumentError.unsupportedSchema
        }
        folders = try values.decode([ProfileFolder].self, forKey: .folders)
        assignments = try values.decode([ProfileFolderAssignment].self, forKey: .assignments)
        mutationRevision = try values.decodeIfPresent(UUID.self, forKey: .mutationRevision)
    }

    init(state: ProfileOrganizationState) {
        schemaVersion = Self.currentSchemaVersion
        mutationRevision = state.mutationRevision
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
        guard (Self.legacySchemaVersion...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw ProfileOrganizationDocumentError.unsupportedSchema
        }

        var folderIDs = Set<UUID>()
        var cleanFolders: [ProfileFolder] = []
        var changed = schemaVersion != Self.currentSchemaVersion
        for var folder in folders {
            guard folderIDs.insert(folder.id).inserted,
                  let cleanName = ProfileFolder.normalizedName(folder.name)
            else {
                throw ProfileOrganizationDocumentError.invalidFolder
            }
            if schemaVersion == Self.legacySchemaVersion,
               folder.parentFolderID != nil {
                throw ProfileOrganizationDocumentError.invalidFolder
            }
            if folder.name != cleanName {
                folder.name = cleanName
                changed = true
            }
            cleanFolders.append(folder)
        }

        let foldersByID = Dictionary(uniqueKeysWithValues: cleanFolders.map { ($0.id, $0) })
        for folder in cleanFolders {
            if let parentFolderID = folder.parentFolderID,
               parentFolderID == folder.id || foldersByID[parentFolderID] == nil {
                throw ProfileOrganizationDocumentError.invalidFolder
            }
        }
        try Self.validateAcyclicHierarchy(cleanFolders)

        var siblingNameKeys = Set<String>()
        for folder in cleanFolders {
            let parentKey = folder.parentFolderID?.uuidString ?? "<root>"
            let siblingKey = "\(parentKey)|\(ProfileFolder.comparisonKey(folder.name))"
            guard siblingNameKeys.insert(siblingKey).inserted else {
                throw ProfileOrganizationDocumentError.duplicateFolderName
            }
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
            assignmentsByProfileID: assignmentsByProfileID,
            mutationRevision: mutationRevision
        )
        if ProfileOrganizationDocument(state: state) != self {
            changed = true
        }
        return (state, changed)
    }

    private static func validateAcyclicHierarchy(_ folders: [ProfileFolder]) throws {
        let parentByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.parentFolderID) })
        var visitState: [UUID: UInt8] = [:]

        for folder in folders where visitState[folder.id] == nil {
            var path: [UUID] = []
            var currentID: UUID? = folder.id
            while let id = currentID {
                if visitState[id] == 1 {
                    throw ProfileOrganizationDocumentError.invalidFolder
                }
                if visitState[id] == 2 {
                    break
                }
                visitState[id] = 1
                path.append(id)
                currentID = parentByID[id] ?? nil
            }
            for id in path {
                visitState[id] = 2
            }
        }
    }
}

struct ProfileOrganizationState: Equatable, Sendable {
    static let empty = ProfileOrganizationState()

    var mutationRevision: UUID?
    private(set) var folders: [ProfileFolder]
    fileprivate(set) var assignmentsByProfileID: [UUID: UUID]

    init(
        folders: [ProfileFolder] = [],
        assignmentsByProfileID: [UUID: UUID] = [:],
        mutationRevision: UUID? = nil
    ) {
        self.mutationRevision = mutationRevision
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

    func childFolders(of parentFolderID: UUID?) -> [ProfileFolder] {
        folders
            .filter { $0.parentFolderID == parentFolderID }
            .sorted(by: ProfileFolder.areInIncreasingOrder)
    }

    /// Returns a stable depth-first list of descendant folder IDs.
    func descendantFolderIDs(of folderID: UUID, includingSelf: Bool = false) -> [UUID] {
        guard folder(withID: folderID) != nil else { return [] }
        var result: [UUID] = includingSelf ? [folderID] : []
        var pending = Array(childFolders(of: folderID).reversed())
        while let folder = pending.popLast() {
            result.append(folder.id)
            pending.append(contentsOf: childFolders(of: folder.id).reversed())
        }
        return result
    }

    func folderPath(for folderID: UUID) -> [ProfileFolder]? {
        guard var folder = self.folder(withID: folderID) else { return nil }
        var path = [folder]
        var seen: Set<UUID> = [folder.id]
        while let parentID = folder.parentFolderID {
            guard seen.insert(parentID).inserted,
                  let parent = self.folder(withID: parentID) else {
                return nil
            }
            path.append(parent)
            folder = parent
        }
        return path.reversed()
    }

    func boundedFolderPath(for folderID: UUID?, maximumUTF8Bytes: Int = 512) -> (components: [String], truncated: Bool) {
        let path = folderID.flatMap { folderPath(for: $0)?.map(\.name) } ?? []
        var components: [String] = []
        var usedBytes = 0
        let separatorBytesInPath = " › ".utf8.count
        for component in path {
            let separatorBytes = components.isEmpty ? 0 : separatorBytesInPath
            let availableBytes = maximumUTF8Bytes - usedBytes - separatorBytes
            let componentBytes = Array(component.utf8)
            if componentBytes.count <= availableBytes {
                components.append(component)
                usedBytes += separatorBytes + componentBytes.count
                continue
            }
            guard availableBytes >= 3 else { return (components, true) }
            let marker = "…"
            let prefixBudget = availableBytes - marker.utf8.count
            var prefix = ""
            for character in component {
                let value = String(character)
                guard prefix.utf8.count + value.utf8.count <= prefixBudget else { break }
                prefix.append(character)
            }
            components.append(prefix + marker)
            return (components, true)
        }
        return (components, false)
    }

    func folderIDsInHierarchyOrder() -> [UUID] {
        var result: [UUID] = []
        var pending = Array(childFolders(of: nil).reversed())
        while let folder = pending.popLast() {
            result.append(folder.id)
            pending.append(contentsOf: childFolders(of: folder.id).reversed())
        }
        return result
    }

    /// Returns the selected folder followed by all descendants in stable tree order.
    func folderIDs(includingDescendantsOf folderID: UUID) -> [UUID] {
        descendantFolderIDs(of: folderID, includingSelf: true)
    }

    func folderDepth(of folderID: UUID) -> Int? {
        guard let path = folderPath(for: folderID) else { return nil }
        return path.count - 1
    }

    func profileIDs(inFolderID folderID: UUID, includingDescendants: Bool) -> [UUID] {
        let folderIDs = Set(descendantFolderIDs(of: folderID, includingSelf: true))
        guard includingDescendants else { return profileIDs(inFolderID: folderID) }
        return assignmentsByProfileID.compactMap { profileID, assignedFolderID in
            folderIDs.contains(assignedFolderID) ? profileID : nil
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func canMoveFolder(_ folderID: UUID, toParentFolderID parentFolderID: UUID?) -> Bool {
        guard let folder = self.folder(withID: folderID) else { return false }
        if let parentFolderID {
            guard self.folder(withID: parentFolderID) != nil,
                  parentFolderID != folderID,
                  !descendantFolderIDs(of: folderID).contains(parentFolderID) else {
                return false
            }
        }
        return !folders.contains {
            $0.id != folderID &&
                $0.parentFolderID == parentFolderID &&
                ProfileFolder.comparisonKey($0.name) == ProfileFolder.comparisonKey(folder.name)
        }
    }

    mutating func moveFolder(
        _ folderID: UUID,
        toParentFolderID parentFolderID: UUID?,
        at date: Date = Date()
    ) throws {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else {
            throw ProfileOrganizationError.folderNotFound
        }
        if let parentFolderID {
            guard self.folder(withID: parentFolderID) != nil,
                  parentFolderID != folderID,
                  !descendantFolderIDs(of: folderID).contains(parentFolderID)
            else {
                throw ProfileOrganizationError.invalidFolderHierarchy
            }
        }
        guard !folders.contains(where: {
            $0.id != folderID &&
                $0.parentFolderID == parentFolderID &&
                ProfileFolder.comparisonKey($0.name) ==
                    ProfileFolder.comparisonKey(folders[index].name)
        }) else {
            throw ProfileOrganizationError.duplicateFolderName
        }
        guard folders[index].parentFolderID != parentFolderID else { return }
        guard canMoveFolder(folderID, toParentFolderID: parentFolderID) else {
            throw ProfileOrganizationError.invalidFolderHierarchy
        }
        folders[index].parentFolderID = parentFolderID
        folders[index].updatedAt = date
        folders.sort(by: ProfileFolder.areInIncreasingOrder)
    }

    mutating func addFolder(_ folder: ProfileFolder) {
        folders.append(folder)
        folders.sort(by: ProfileFolder.areInIncreasingOrder)
    }

    mutating func addFolders(_ newFolders: [ProfileFolder]) {
        guard !newFolders.isEmpty else { return }
        folders.append(contentsOf: newFolders)
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

    func canRemoveFolder(withID folderID: UUID) -> Bool {
        guard let folder = folder(withID: folderID) else { return false }
        let promotedChildNames = Set(
            childFolders(of: folderID).map { ProfileFolder.comparisonKey($0.name) }
        )
        return !folders.contains {
            $0.id != folderID &&
                $0.parentFolderID == folder.parentFolderID &&
                promotedChildNames.contains(ProfileFolder.comparisonKey($0.name))
        }
    }

    mutating func removeFolder(withID folderID: UUID, at date: Date = Date()) throws -> [UUID] {
        guard let removedFolder = folder(withID: folderID) else {
            throw ProfileOrganizationError.folderNotFound
        }
        guard canRemoveFolder(withID: folderID) else {
            throw ProfileOrganizationError.folderDeletionConflict
        }
        let affectedProfileIDs = profileIDs(inFolderID: folderID)
        folders.removeAll { $0.id == folderID }
        for index in folders.indices where folders[index].parentFolderID == folderID {
            folders[index].parentFolderID = removedFolder.parentFolderID
            folders[index].updatedAt = date
        }
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
    case invalidFolderHierarchy
    case folderDeletionConflict

    var errorDescription: String? {
        switch self {
        case .invalidFolderName:
            String(format: NSLocalizedString("userError.034", tableName: "Errors", bundle: .main, value: "Проверь название папки: от 1 до %@ символов без переносов строк.", comment: ""), String(describing: ProfileFolder.maximumNameLength))
        case .duplicateFolderName:
            NSLocalizedString("userError.035", tableName: "Errors", bundle: .main, value: "Папка с таким именем уже существует.", comment: "")
        case .folderNotFound:
            NSLocalizedString("userError.036", tableName: "Errors", bundle: .main, value: "Папка уже удалена или недоступна. Профили не изменены.", comment: "")
        case .profileNotFound:
            NSLocalizedString("userError.037", tableName: "Errors", bundle: .main, value: "Один из профилей уже удалён. Папка не изменена.", comment: "")
        case .storageUnavailable:
            NSLocalizedString("userError.038", tableName: "Errors", bundle: .main, value: "Папки временно недоступны. Профили и данные браузеров не изменены.", comment: "")
        case .invalidFolderHierarchy:
            NSLocalizedString("userError.206", tableName: "Errors", bundle: .main, value: "Нельзя вложить папку в неё саму или в её подпапку.", comment: "")
        case .folderDeletionConflict:
            NSLocalizedString("userError.207", tableName: "Errors", bundle: .main, value: "Не удалось удалить папку: переименуй или перемести конфликтующую подпапку. Профили сохранены.", comment: "")
        }
    }
}

enum ProfileOrganizationDocumentError: LocalizedError {
    case unsupportedSchema
    case invalidFolder
    case duplicateFolderName
    case duplicateAssignment

    var errorDescription: String? {
        NSLocalizedString("userError.039", tableName: "Errors", bundle: .main, value: "Файл папок имеет неподдерживаемый или повреждённый формат.", comment: "")
    }
}
