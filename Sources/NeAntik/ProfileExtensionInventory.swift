import Darwin
import CoreFoundation
import Foundation

enum ProfileExtensionInventoryError: LocalizedError, Equatable {
    case unsafeEntry, changed, limitExceeded, unsupportedPreferences
    var errorDescription: String? {
        switch self {
        case .unsafeEntry: "Не удалось безопасно прочитать расширения. Закрой профиль и проверь его данные; ссылки и чужие файлы не открываются."
        case .changed: "Данные расширений изменились во время чтения. Закрой профиль и обнови список."
        case .limitExceeded: "Список расширений превышает лимит локального просмотра. Открой управление в браузере."
        case .unsupportedPreferences: "Сохранённые настройки расширений не удалось прочитать. Открой управление в браузере; данные не изменены."
        }
    }
}

struct ProfileExtensionRecord: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case enabled, disabled, unknown }
    enum Source: String, Sendable { case unpacked, packaged, other, unknown }
    let id: String
    let name: String
    let version: String?
    let manifestVersion: Int?
    let permissions: [String]
    let optionalPermissions: [String]
    let state: State
    let source: Source
    let metadataNeedsBrowser: Bool
    let conflictingMetadata: Bool
}

struct ProfileExtensionSnapshot: Equatable, Sendable {
    let records: [ProfileExtensionRecord]
    let packageCount: Int
    let preferencesPresent: Bool
    let omittedRecords: Int
    let capturedAt: Date
}

/// Reads a closed profile's Chromium metadata, never external unpacked paths.
/// Manifest permissions are requests, not proof of grants or publisher trust.
enum ProfileExtensionInventory {
    static let maximumPreferencesBytes = 8 * 1_024 * 1_024
    static let maximumDirectoryEntries = 1_024
    static let maximumRecords = 256

    static func scan(browserData: URL, beforeValidation: (() throws -> Void)? = nil) throws -> ProfileExtensionSnapshot {
        try Task.checkCancellation()
        guard let root = try directory(browserData) else {
            return .init(records: [], packageCount: 0, preferencesPresent: false, omittedRecords: 0, capturedAt: Date())
        }
        defer { Darwin.close(root) }
        guard let profile = try childDirectory(root, "Default") else {
            return .init(records: [], packageCount: 0, preferencesPresent: false, omittedRecords: 0, capturedAt: Date())
        }
        defer { Darwin.close(profile) }
        let rootIdentity = try BackupFS.identity(root)
        let before = try BackupFS.identity(profile)
        let packages = try packageIDs(profile)
        let preferenceData = try read(profile, "Preferences", maximum: maximumPreferencesBytes)
        let secureData = try read(profile, "Secure Preferences", maximum: maximumPreferencesBytes)
        let ordinary = try settings(preferenceData?.data), secure = try settings(secureData?.data)
        let combined = ordinary.merging(secure) { _, secured in secured }
        var records: [ProfileExtensionRecord] = [], omitted = 0
        guard combined.count <= maximumRecords else { throw ProfileExtensionInventoryError.limitExceeded }
        for id in combined.keys.sorted() {
            try Task.checkCancellation()
            guard validID(id), let value = combined[id] as? [String: Any] else { omitted += 1; continue }
            let manifest = value["manifest"] as? [String: Any] ?? [:]
            let rawName = safeText(manifest["name"], maximumBytes: 512)
            let resolvedName = rawName.flatMap { $0.hasPrefix("__MSG_") ? nil : $0 }
            let unresolved = resolvedName == nil
            let conflict: Bool
            if let lhs = ordinary[id], let rhs = secure[id] { conflict = !NSDictionary(dictionary: ["entry": lhs]).isEqual(to: ["entry": rhs]) }
            else { conflict = false }
            // Exact M156 ManifestLocation hides internal component extensions
            // from user management. A conflicting record is never hidden.
            if !conflict, let location = integer(value["location"]), [5, 10].contains(location) { continue }
            records.append(.init(id: id, name: resolvedName ?? "Расширение \(id.prefix(8))",
                version: safeText(manifest["version"], maximumBytes: 128),
                manifestVersion: integer(manifest["manifest_version"]),
                permissions: try strings(manifest["permissions"]) + strings(manifest["host_permissions"]),
                optionalPermissions: try strings(manifest["optional_permissions"]) + strings(manifest["optional_host_permissions"]),
                state: conflict ? .unknown : savedState(value), source: conflict ? .unknown : savedSource(value),
                metadataNeedsBrowser: unresolved || manifest.isEmpty, conflictingMetadata: conflict))
        }
        try beforeValidation?()
        try packages.validate(parent: profile)
        try validateRead(profile, "Preferences", preferenceData)
        try validateRead(profile, "Secure Preferences", secureData)
        guard try BackupFS.identity(profile) == before else { throw ProfileExtensionInventoryError.changed }
        try BackupFS.validateDirectoryPath(browserData, rootIdentity)
        try BackupFS.validateDirectoryPath(browserData.appendingPathComponent("Default", isDirectory: true), before)
        try Task.checkCancellation()
        return .init(records: records, packageCount: packages.identities.count, preferencesPresent: preferenceData != nil || secureData != nil,
                     omittedRecords: omitted, capturedAt: Date())
    }

    private static func settings(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProfileExtensionInventoryError.unsupportedPreferences
        }
        guard let extensions = document["extensions"] else { return [:] }
        guard let object = extensions as? [String: Any] else { throw ProfileExtensionInventoryError.unsupportedPreferences }
        guard let settings = object["settings"] else { return [:] }
        guard let settings = settings as? [String: Any] else {
            throw ProfileExtensionInventoryError.unsupportedPreferences
        }
        guard settings.count <= maximumRecords else { throw ProfileExtensionInventoryError.limitExceeded }
        return settings
    }

    static func validID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (97...112).contains($0) }
    }

    // Chromium stores disable reasons separately; absent data is never green.
    // M156 base 634b046f: ExtensionPrefs::IsExtensionDisabled uses nonempty
    // disable reasons. Enabled still requires live/blocklist/load evidence.
    private static func savedState(_ object: [String: Any]) -> ProfileExtensionRecord.State {
        // Until the current runtime's stored schema is qualified, even an
        // empty reasons array is unknown. Never infer enabled from legacy state.
        if let reasons = object["disable_reasons"] as? [Any], !reasons.isEmpty,
           reasons.allSatisfy({ integer($0).map { $0 > 0 } == true }) { return .disabled }
        return .unknown
    }

    private static func savedSource(_ object: [String: Any]) -> ProfileExtensionRecord.Source {
        if let location = integer(object["location"]) {
            if location == 4 { return .unpacked }
            if location == 1 { return .packaged }
            return .other
        }
        return .unknown
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue) else { return nil }
        return integer
    }

    private static func safeText(_ value: Any?, maximumBytes: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximumBytes,
              PersistedInlineText.isSafe(text) else { return nil }
        return text
    }

    private static func strings(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let values = value as? [String], values.count <= 256 else { throw ProfileExtensionInventoryError.unsupportedPreferences }
        return try values.map {
            guard let safe = safeText($0, maximumBytes: 2_048) else { throw ProfileExtensionInventoryError.unsupportedPreferences }
            return safe
        }
    }

    private struct CapturedPackages {
        let identity: BackupIdentity?
        let identities: [String: BackupIdentity]
        func validate(parent: Int32) throws {
            guard try BackupFS.entry(parent, "Extensions") == identity else { throw ProfileExtensionInventoryError.changed }
            guard identity != nil else { return }
            guard let directory = try ProfileExtensionInventory.childDirectory(parent, "Extensions") else { throw ProfileExtensionInventoryError.changed }
            defer { Darwin.close(directory) }
            guard try BackupFS.identity(directory) == identity else { throw ProfileExtensionInventoryError.changed }
            for (id, captured) in identities {
                guard try BackupFS.entry(directory, id) == captured else { throw ProfileExtensionInventoryError.changed }
            }
        }
    }

    private static func packageIDs(_ profile: Int32) throws -> CapturedPackages {
        guard let directory = try childDirectory(profile, "Extensions") else { return .init(identity: nil, identities: [:]) }
        defer { Darwin.close(directory) }
        let before = try BackupFS.identity(directory)
        let copy = dup(directory); guard copy >= 0 else { throw ProfileExtensionInventoryError.unsafeEntry }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw ProfileExtensionInventoryError.unsafeEntry }
        defer { closedir(stream) }
        var names: [String: BackupIdentity] = [:], count = 0
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw ProfileExtensionInventoryError.unsafeEntry }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw ProfileExtensionInventoryError.unsafeEntry }
            if name == "." || name == ".." { continue }
            count += 1; guard count <= maximumDirectoryEntries else { throw ProfileExtensionInventoryError.limitExceeded }
            guard validID(name) else { continue }
            guard let child = try childDirectory(directory, name) else { throw ProfileExtensionInventoryError.changed }
            names[name] = try BackupFS.identity(child)
            Darwin.close(child)
        }
        guard try BackupFS.identity(directory) == before else { throw ProfileExtensionInventoryError.changed }
        return .init(identity: before, identities: names)
    }

    private static func directory(_ url: URL) throws -> Int32? {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ProfileExtensionInventoryError.unsafeEntry }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ProfileExtensionInventoryError.unsafeEntry }
        do {
            for name in url.pathComponents.dropFirst() {
                try BackupFS.validateName(name)
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    if errno == ENOENT { Darwin.close(fd); return nil }
                    throw ProfileExtensionInventoryError.unsafeEntry
                }
                Darwin.close(fd); fd = next
            }
            guard try BackupFS.identity(fd).uid == geteuid() else { throw ProfileExtensionInventoryError.unsafeEntry }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private static func childDirectory(_ parent: Int32, _ name: String) throws -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ProfileExtensionInventoryError.unsafeEntry
        }
        guard let identity = try? BackupFS.identity(fd), identity.uid == geteuid() else {
            Darwin.close(fd); throw ProfileExtensionInventoryError.unsafeEntry
        }
        return fd
    }

    private struct CapturedFile { let data: Data; let identity: BackupIdentity }

    private static func validateRead(_ directory: Int32, _ name: String, _ captured: CapturedFile?) throws {
        guard try BackupFS.entry(directory, name) == captured?.identity else { throw ProfileExtensionInventoryError.changed }
    }

    private static func read(_ directory: Int32, _ name: String, maximum: Int) throws -> CapturedFile? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ProfileExtensionInventoryError.unsafeEntry
        }
        defer { Darwin.close(fd) }
        let before = try BackupFS.identity(fd)
        do { try before.validateFile(device: nil) } catch { throw ProfileExtensionInventoryError.unsafeEntry }
        guard before.size <= maximum else { throw ProfileExtensionInventoryError.limitExceeded }
        var data = Data()
        while data.count < Int(before.size) {
            try Task.checkCancellation()
            let chunk = try BackupFS.read(fd, at: off_t(data.count), count: min(65_536, Int(before.size) - data.count))
            guard !chunk.isEmpty else { throw ProfileExtensionInventoryError.changed }
            data.append(chunk)
        }
        guard try BackupFS.identity(fd) == before, try BackupFS.entry(directory, name) == before else {
            throw ProfileExtensionInventoryError.changed
        }
        return CapturedFile(data: data, identity: before)
    }
}
