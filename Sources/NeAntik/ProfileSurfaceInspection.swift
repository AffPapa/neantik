import Foundation
import SwiftUI

/// A deliberately small, local-only view of Chromium extensions.  The
/// scanner reads manifests from the profile's Extensions directory and never
/// returns cookies, URLs visited, or manifest contents verbatim.
struct InstalledExtension: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let permissionCount: Int
    let hostAccessCount: Int
    let hasBroadHostAccess: Bool
    let hasSensitivePermission: Bool
    let source: Source

    enum Source: String, Codable, Sendable {
        case profile
        case unavailable
    }

    var risk: Risk {
        if hasBroadHostAccess || hasSensitivePermission { return .review }
        if permissionCount > 0 || hostAccessCount > 0 { return .limited }
        return .low
    }

    enum Risk: String, Codable, Equatable, Sendable {
        case low
        case limited
        case review
    }
}

struct ExtensionSurfaceReport: Equatable, Sendable {
    let extensions: [InstalledExtension]
    let isAvailable: Bool
    let issue: String?

    var requiresReview: Bool {
        extensions.contains { $0.risk == .review }
    }

    static let unavailable = Self(
        extensions: [], isAvailable: false,
        issue: "Папка расширений недоступна для безопасной проверки."
    )
}

struct ProfileStorageSurfaceReport: Equatable, Sendable {
    struct Area: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let namespaceCount: Int
        let fileCount: Int
        let isAvailable: Bool
        let issue: String?

        var hasState: Bool {
            namespaceCount > 0 || fileCount > 0
        }
    }

    let areas: [Area]
    let isAvailable: Bool
    let issue: String?

    var hasBrowserState: Bool {
        areas.contains(where: \.hasState)
    }

    var requiresReview: Bool {
        !isAvailable || areas.contains { !$0.isAvailable }
    }
}

enum ExtensionSurfaceScanner {
    static let maximumExtensions = 128
    static let maximumManifestBytes = 512 * 1_024

    /// `profileDirectory` is the Chromium user-data directory for exactly
    /// one NeAntik workplace. Symlinks and paths outside this directory are
    /// ignored to keep the inspection bounded and profile-local.
    static func scan(profileDirectory: URL,
                     fileManager: FileManager = .default) -> ExtensionSurfaceReport {
        let directory = profileDirectory
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            // Chromium omits Extensions until the first extension is
            // installed. That is a healthy empty result, not an error.
            return ExtensionSurfaceReport(extensions: [], isAvailable: true, issue: nil)
        }
        guard isDirectory.boolValue else { return .unavailable }

        guard let ids = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return .unavailable }

        var result: [InstalledExtension] = []
        for idURL in ids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard result.count < maximumExtensions,
                  Self.isSafeChild(idURL, parent: directory),
                  Self.isDirectory(idURL),
                  !Self.isSymbolicLink(idURL) else { continue }
            // We only inspect the newest lexical version. Selecting it in a
            // bounded single pass avoids allocating and sorting every
            // historical version directory on old, extension-heavy profiles.
            guard let versionURL = newestVersionDirectory(
                in: idURL,
                fileManager: fileManager
            ) else { continue }
            do {
                guard Self.isSafeChild(versionURL, parent: idURL),
                      Self.isDirectory(versionURL),
                      !Self.isSymbolicLink(versionURL) else { continue }
                let manifestURL = versionURL.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe]),
                      data.count <= maximumManifestBytes,
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let manifest = object as? [String: Any] else { continue }
                result.append(makeExtension(id: idURL.lastPathComponent,
                                            version: versionURL.lastPathComponent,
                                            manifest: manifest))
            }
        }
        return ExtensionSurfaceReport(extensions: result, isAvailable: true, issue: nil)
    }

    private static func isSafeChild(_ item: URL, parent: URL) -> Bool {
        item.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path &&
            !item.lastPathComponent.contains("/") && !item.lastPathComponent.isEmpty
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func newestVersionDirectory(
        in directory: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: URL?
        for case let candidate as URL in enumerator {
            enumerator.skipDescendants()
            guard Self.isSafeChild(candidate, parent: directory),
                  Self.isDirectory(candidate),
                  !Self.isSymbolicLink(candidate)
            else { continue }
            if newest == nil ||
                candidate.lastPathComponent > newest!.lastPathComponent {
                newest = candidate
            }
        }
        return newest
    }

    private static func makeExtension(id: String, version: String, manifest: [String: Any]) -> InstalledExtension {
        let candidate = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = candidate.map { String($0.prefix(120)) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Расширение (\(id.prefix(12)))"
        let permissions = values(manifest["permissions"])
        let optional = values(manifest["optional_permissions"])
        let hosts = values(manifest["host_permissions"]) + values(manifest["optional_host_permissions"])
        let allPermissions = permissions + optional
        let sensitive = Set(["debugger", "proxy", "webRequest", "webRequestBlocking", "nativeMessaging", "management", "downloads"]).intersection(allPermissions).isEmpty == false
        let broad = hosts.contains { $0 == "<all_urls>" || $0 == "*://*/*" || $0 == "http://*/*" || $0 == "https://*/*" }
        return InstalledExtension(id: id, name: name, version: version,
                                  permissionCount: allPermissions.count,
                                  hostAccessCount: hosts.count,
                                  hasBroadHostAccess: broad,
                                  hasSensitivePermission: sensitive,
                                  source: .profile)
    }

    private static func values(_ value: Any?) -> [String] {
        (value as? [String] ?? []).filter { !$0.isEmpty }.prefix(64).map { String($0.prefix(512)) }
    }
}

enum ProfileStorageSurfaceScanner {
    private struct AreaSpec {
        let id: String
        let title: String
        let relativePath: String
    }

    static let maximumEntriesPerArea = 256

    private static let areaSpecs = [
        AreaSpec(
            id: "local-storage",
            title: "localStorage",
            relativePath: "Default/Local Storage"
        ),
        AreaSpec(
            id: "session-storage",
            title: "sessionStorage",
            relativePath: "Default/Session Storage"
        ),
        AreaSpec(
            id: "indexed-db",
            title: "IndexedDB",
            relativePath: "Default/IndexedDB"
        ),
        AreaSpec(
            id: "service-workers",
            title: "Service workers",
            relativePath: "Default/Service Worker"
        ),
        AreaSpec(
            id: "cache-storage",
            title: "Cache storage",
            relativePath: "Default/Cache/Cache_Data"
        ),
    ]

    /// Counts Chromium storage namespaces without reading keys, values, URLs
    /// or origin strings. The result is safe for diagnostics because it only
    /// says whether each local storage surface exists and has state.
    static func scan(
        profileDirectory: URL,
        fileManager: FileManager = .default
    ) -> ProfileStorageSurfaceReport {
        var rootMetadata = stat()
        guard lstat(profileDirectory.path, &rootMetadata) == 0 else {
            if errno == ENOENT {
                return ProfileStorageSurfaceReport(
                    areas: emptyAreas(),
                    isAvailable: true,
                    issue: nil
                )
            }
            return unavailable("Папка профиля недоступна.")
        }
        guard rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            return unavailable("Папка профиля была заменена небезопасной ссылкой.")
        }

        let areas = areaSpecs.map {
            scanArea(
                $0,
                profileDirectory: profileDirectory,
                fileManager: fileManager
            )
        }
        return ProfileStorageSurfaceReport(
            areas: areas,
            isAvailable: true,
            issue: nil
        )
    }

    private static func scanArea(
        _ spec: AreaSpec,
        profileDirectory: URL,
        fileManager: FileManager
    ) -> ProfileStorageSurfaceReport.Area {
        let directory = profileDirectory.appendingPathComponent(
            spec.relativePath,
            isDirectory: true
        )
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0 else {
            return ProfileStorageSurfaceReport.Area(
                id: spec.id,
                title: spec.title,
                namespaceCount: 0,
                fileCount: 0,
                isAvailable: errno == ENOENT,
                issue: errno == ENOENT ? nil : "Не удалось проверить область."
            )
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            return ProfileStorageSurfaceReport.Area(
                id: spec.id,
                title: spec.title,
                namespaceCount: 0,
                fileCount: 0,
                isAvailable: false,
                issue: "Область не является папкой."
            )
        }

        guard let counts = boundedCounts(
            in: directory,
            fileManager: fileManager
        ) else {
            return ProfileStorageSurfaceReport.Area(
                id: spec.id,
                title: spec.title,
                namespaceCount: 0,
                fileCount: 0,
                isAvailable: false,
                issue: "Не удалось прочитать область."
            )
        }

        return ProfileStorageSurfaceReport.Area(
            id: spec.id,
            title: spec.title,
            namespaceCount: counts.namespaceCount,
            fileCount: counts.fileCount,
            isAvailable: !counts.reachedLimit,
            issue: counts.reachedLimit
                ? "Слишком много записей для быстрой проверки."
                : nil
        )
    }

    private struct BoundedCounts {
        let namespaceCount: Int
        let fileCount: Int
        let reachedLimit: Bool
    }

    private static func boundedCounts(
        in directory: URL,
        fileManager: FileManager
    ) -> BoundedCounts? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var inspected = 0
        var namespaceCount = 0
        var fileCount = 0
        for case let entry as URL in enumerator {
            enumerator.skipDescendants()
            inspected += 1
            if inspected > maximumEntriesPerArea {
                return BoundedCounts(
                    namespaceCount: namespaceCount,
                    fileCount: fileCount,
                    reachedLimit: true
                )
            }
            guard ExtensionSurfaceScanner.isSafeChildForSurfaceInspection(
                entry,
                parent: directory
            ) else { continue }
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values?.isSymbolicLink != true else { continue }
            if values?.isDirectory == true {
                namespaceCount += 1
            } else if values?.isRegularFile == true {
                fileCount += 1
            }
        }

        return BoundedCounts(
            namespaceCount: namespaceCount,
            fileCount: fileCount,
            reachedLimit: false
        )
    }

    private static func emptyAreas() -> [ProfileStorageSurfaceReport.Area] {
        areaSpecs.map {
            ProfileStorageSurfaceReport.Area(
                id: $0.id,
                title: $0.title,
                namespaceCount: 0,
                fileCount: 0,
                isAvailable: true,
                issue: nil
            )
        }
    }

    private static func unavailable(
        _ issue: String
    ) -> ProfileStorageSurfaceReport {
        ProfileStorageSurfaceReport(
            areas: emptyAreas(),
            isAvailable: false,
            issue: issue
        )
    }
}

extension ExtensionSurfaceScanner {
    fileprivate static func isSafeChildForSurfaceInspection(
        _ item: URL,
        parent: URL
    ) -> Bool {
        isSafeChild(item, parent: parent)
    }
}

struct MemoryProcessSnapshot: Equatable, Sendable {
    let profileID: UUID
    let processID: Int32
    let residentBytes: UInt64
    let lastActivity: Date
    let isFocused: Bool
}

enum MemorySavingAction: Equatable, Sendable {
    case keepRunning
    case suspend
    case resume
}

struct MemorySavingDecision: Equatable, Sendable {
    let profileID: UUID
    let action: MemorySavingAction
    let explanation: String
}

/// Deterministic policy only. The process manager owns the actual reversible
/// suspend/resume operation, so policy tests remain safe and platform-neutral.
enum AutomaticMemorySavingPolicy {
    static let defaultResidentThreshold: UInt64 = 1_500 * 1_024 * 1_024
    static let defaultInactiveInterval: TimeInterval = 15 * 60

    static func decide(_ snapshots: [MemoryProcessSnapshot],
                       now: Date = Date(),
                       residentThreshold: UInt64 = defaultResidentThreshold,
                       inactiveInterval: TimeInterval = defaultInactiveInterval) -> [MemorySavingDecision] {
        let total = snapshots.reduce(UInt64(0)) { $0 &+ $1.residentBytes }
        let pressure = total >= residentThreshold || snapshots.count >= 8
        return snapshots.map { snapshot in
            if snapshot.isFocused || !pressure {
                return MemorySavingDecision(profileID: snapshot.profileID, action: .keepRunning,
                                            explanation: snapshot.isFocused ? "Текущее рабочее место остаётся активным." : "Памяти достаточно.")
            }
            let inactive = now.timeIntervalSince(snapshot.lastActivity)
            if inactive >= inactiveInterval {
                return MemorySavingDecision(profileID: snapshot.profileID, action: .suspend,
                                            explanation: "Неактивное рабочее место временно приостановлено для экономии памяти.")
            }
            return MemorySavingDecision(profileID: snapshot.profileID, action: .keepRunning,
                                        explanation: "Рабочее место недавно использовалось.")
        }
    }
}

struct ProfileStorageSurfaceInspectionView: View {
    let profileDirectory: URL
    @State private var report: ProfileStorageSurfaceReport?

    init(profileDirectory: URL) {
        self.profileDirectory = profileDirectory
        _report = State(initialValue: nil)
    }

    var body: some View {
        GroupBox {
            if let report {
                if let issue = report.issue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !report.hasBrowserState {
                    Label("Локальное состояние пока пустое", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.areas) { area in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: area.isAvailable ? "internaldrive" : "exclamationmark.triangle")
                                    .foregroundStyle(area.isAvailable ? Color.secondary : Color.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(area.title)
                                    Text(Self.detail(for: area))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            } else {
                ProgressView("Проверяю локальное состояние…")
                    .controlSize(.small)
            }
        } label: {
            Label("Локальное хранилище", systemImage: "internaldrive")
        }
        .task(id: profileDirectory.path) {
            report = await Task.detached(priority: .utility) {
                ProfileStorageSurfaceScanner.scan(
                    profileDirectory: profileDirectory
                )
            }.value
        }
    }

    private static func detail(
        for area: ProfileStorageSurfaceReport.Area
    ) -> String {
        if let issue = area.issue {
            return issue
        }
        if !area.hasState {
            return "нет локального состояния"
        }
        return "областей: \(area.namespaceCount), файлов: \(area.fileCount)"
    }
}

struct ExtensionSurfaceInspectionView: View {
    let profileDirectory: URL
    @State private var report: ExtensionSurfaceReport?

    init(profileDirectory: URL) {
        self.profileDirectory = profileDirectory
        _report = State(initialValue: nil)
    }

    var body: some View {
        GroupBox {
            if let report {
                if report.isAvailable {
                    if report.extensions.isEmpty {
                        Label("Расширения не установлены", systemImage: "checkmark.shield")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.extensions) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: item.risk == .review ? "exclamationmark.triangle" : "puzzlepiece.extension")
                                        .foregroundStyle(item.risk == .review ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                        Text(Self.detail(for: item))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                } else {
                    Label(report.issue ?? "Проверка расширений недоступна", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Проверяю расширения…")
                    .controlSize(.small)
            }
        } label: {
            Label("Расширения", systemImage: "puzzlepiece.extension")
        }
        .task(id: profileDirectory.path) {
            report = await Task.detached(priority: .utility) {
                ExtensionSurfaceScanner.scan(profileDirectory: profileDirectory)
            }.value
        }
    }

    private static func detail(for item: InstalledExtension) -> String {
        let access = item.hostAccessCount == 0 ? "нет доступа к сайтам" :
            "доступ к сайтам: " + String(item.hostAccessCount)
        let permissions = item.permissionCount == 0 ? "без разрешений" :
            "разрешений: " + String(item.permissionCount)
        let value = access + " · " + permissions
        return item.risk == .review ? "Нужна проверка · " + value : value
    }
}
