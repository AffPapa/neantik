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
    /// Default-locale disk label, not the running browser's chosen UI language.
    let nameLocale: String?
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
    static let maximumLocaleBytes = 256 * 1_024
    static let maximumTotalLocaleBytes = 8 * 1_024 * 1_024

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
        var localeCaptures: [LocaleCapture] = [], localeBytes = 0
        guard combined.count <= maximumRecords else { throw ProfileExtensionInventoryError.limitExceeded }
        for id in combined.keys.sorted() {
            try Task.checkCancellation()
            guard validID(id), let value = combined[id] as? [String: Any] else { omitted += 1; continue }
            let manifest = value["manifest"] as? [String: Any] ?? [:]
            let rawName = safeText(manifest["name"], maximumBytes: 512)
            let conflict: Bool
            if let lhs = ordinary[id], let rhs = secure[id] { conflict = !NSDictionary(dictionary: ["entry": lhs]).isEqual(to: ["entry": rhs]) }
            else { conflict = false }
            // Exact M156 ManifestLocation hides internal component extensions
            // from user management. A conflicting record is never hidden.
            if !conflict, let location = integer(value["location"]), [5, 10].contains(location) { continue }
            var resolvedName = rawName.flatMap { $0.hasPrefix("__MSG_") ? nil : $0 }
            var nameLocale: String?
            if resolvedName == nil, !conflict, savedSource(value) == .packaged,
               let rawName, let locale = safeText(manifest["default_locale"], maximumBytes: 32),
               validLocale(locale), let version = safeText(manifest["version"], maximumBytes: 128) {
                var capture = LocaleCapture()
                resolvedName = try localizedName(rawName, locale: locale, version: version, id: id,
                    savedPath: value["path"], browserData: browserData, profile: profile,
                    capture: &capture, totalBytes: &localeBytes)
                localeCaptures.append(capture)
                if resolvedName != nil { nameLocale = locale }
            }
            let unresolved = resolvedName == nil
            records.append(.init(id: id, name: resolvedName ?? "Расширение \(id.prefix(8))",
                version: safeText(manifest["version"], maximumBytes: 128),
                manifestVersion: integer(manifest["manifest_version"]),
                permissions: try strings(manifest["permissions"]) + strings(manifest["host_permissions"]),
                optionalPermissions: try strings(manifest["optional_permissions"]) + strings(manifest["optional_host_permissions"]),
                state: conflict ? .unknown : savedState(value), source: conflict ? .unknown : savedSource(value),
                metadataNeedsBrowser: unresolved || manifest.isEmpty, conflictingMetadata: conflict, nameLocale: nameLocale))
        }
        try beforeValidation?()
        try packages.validate(parent: profile)
        for capture in localeCaptures { try capture.validate(profile: profile) }
        try validateRead(profile, "Preferences", preferenceData)
        try validateRead(profile, "Secure Preferences", secureData)
        guard try BackupFS.identity(profile) == before else { throw ProfileExtensionInventoryError.changed }
        try BackupFS.validateDirectoryPath(browserData, rootIdentity)
        try BackupFS.validateDirectoryPath(browserData.appendingPathComponent("Default", isDirectory: true), before)
        try Task.checkCancellation()
        return .init(records: records, packageCount: packages.identities.count, preferencesPresent: preferenceData != nil || secureData != nil,
                     omittedRecords: omitted, capturedAt: Date())
    }

    /// Captures every traversed entry, including missing directories/files.
    /// Reopening relative to Default after the scan catches swaps and changes
    /// without retaining hundreds of file descriptors for a large inventory.
    private struct LocaleCapture {
        struct Step { let name: String; let identity: BackupIdentity?; let isDirectory: Bool }
        var steps: [Step] = []
        mutating func openDirectory(_ parent: Int32, _ name: String) throws -> Int32? {
            let fd = try childDirectory(parent, name)
            do {
                steps.append(.init(name: name, identity: try fd.map { try BackupFS.identity($0) }, isDirectory: true))
                return fd
            } catch {
                if let fd { Darwin.close(fd) }
                throw error
            }
        }
        func validate(profile: Int32) throws {
            var parent = profile
            var opened: [Int32] = []
            defer { for fd in opened { Darwin.close(fd) } }
            for step in steps {
                try Task.checkCancellation()
                guard try BackupFS.entry(parent, step.name) == step.identity else { throw ProfileExtensionInventoryError.changed }
                if !step.isDirectory || step.identity == nil { return }
                guard let fd = try childDirectory(parent, step.name) else { throw ProfileExtensionInventoryError.changed }
                opened.append(fd)
                guard try BackupFS.identity(fd) == step.identity else { throw ProfileExtensionInventoryError.changed }
                parent = fd
            }
        }
    }

    private static func validLocale(_ text: String) -> Bool {
        text.utf8.first.map { (65...90).contains($0) || (97...122).contains($0) } == true &&
        text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }

    private static func localizedName(_ raw: String, locale: String, version: String, id: String,
        savedPath: Any?, browserData: URL, profile: Int32, capture: inout LocaleCapture, totalBytes: inout Int) throws -> String? {
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.utf8.count > 8 else { return nil }
        let key = String(raw.dropFirst(6).dropLast(2)).lowercased()
        guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
              version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        guard let packages = try capture.openDirectory(profile, "Extensions") else { return nil }
        defer { Darwin.close(packages) }
        guard let package = try capture.openDirectory(packages, id) else { return nil }
        defer { Darwin.close(package) }
        let names = try directoryNames(package).filter { name in
            if name == version { return true }
            guard name.hasPrefix(version + "_") else { return false }
            let suffix = name.dropFirst(version.count + 1)
            return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
        }
        // Multiple versions of the same manifest version are ambiguous. Never
        // guess an active package from lexical order or follow Preferences.path.
        guard names.count == 1, let selected = names.first else { return nil }
        if let savedPath {
            let relative = "\(id)/\(selected)"
            let absolute = browserData.appendingPathComponent("Default/Extensions/" + relative).path
            guard let path = savedPath as? String, path == relative || path == absolute else { return nil }
        }
        guard let versionDirectory = try capture.openDirectory(package, selected) else { return nil }
        defer { Darwin.close(versionDirectory) }
        guard let locales = try capture.openDirectory(versionDirectory, "_locales") else { return nil }
        defer { Darwin.close(locales) }
        guard let language = try capture.openDirectory(locales, locale) else { return nil }
        defer { Darwin.close(language) }
        let file = try read(language, "messages.json", maximum: maximumLocaleBytes)
        capture.steps.append(.init(name: "messages.json", identity: file?.identity, isDirectory: false))
        guard let file else { return nil }
        totalBytes += file.data.count
        guard totalBytes <= maximumTotalLocaleBytes else { throw ProfileExtensionInventoryError.limitExceeded }
        guard (try? ImportJSONShape.validate(file.data)) != nil,
              let messages = try? JSONSerialization.jsonObject(with: file.data) as? [String: Any], messages.count <= 4_096 else { return nil }
        let matches = messages.filter { $0.key.lowercased() == key }
        guard matches.count == 1, let message = matches.first?.value as? [String: Any],
              let label = safeText(message["message"], maximumBytes: 512), !label.contains("$") else { return nil }
        // Placeholder expansion belongs to Chromium. A partial rendering must
        // not be passed off as the extension's actual name.
        return label
    }

    private static func directoryNames(_ directory: Int32) throws -> [String] {
        let before = try BackupFS.identity(directory)
        let copy = dup(directory); guard copy >= 0 else { throw ProfileExtensionInventoryError.unsafeEntry }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw ProfileExtensionInventoryError.unsafeEntry }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw ProfileExtensionInventoryError.unsafeEntry }
                break
            }
            guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }) else { throw ProfileExtensionInventoryError.unsafeEntry }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= maximumDirectoryEntries else { throw ProfileExtensionInventoryError.limitExceeded }
        }
        guard try BackupFS.identity(directory) == before else { throw ProfileExtensionInventoryError.changed }
        return names
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
