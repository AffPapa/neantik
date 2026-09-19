import CryptoKit
import Foundation

/// The only decision required by the quick-create flow. All other profile
/// values are derived by NeAntik and remain editable from the advanced view.
enum ProfilePurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case work, research, testing, personal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .work: "Работа"
        case .research: "Исследование"
        case .testing: "Тестирование"
        case .personal: "Личное"
        }
    }
    var defaultTag: String { title.lowercased() }
}

struct ProfileCreationRequest: Equatable, Sendable {
    let name: String
    let purpose: ProfilePurpose
    let proxy: ProxyConfiguration?
    let startURL: String

    init(name: String, purpose: ProfilePurpose, proxy: ProxyConfiguration? = nil,
         startURL: String = BrowserProfile.defaultStartURL) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.purpose = purpose
        self.proxy = proxy
        self.startURL = startURL
    }
}

enum ProfileCreationWizard {
    static func makeProfile(from request: ProfileCreationRequest,
                            now: Date = Date()) throws -> BrowserProfile {
        guard BrowserProfile.isValidName(request.name),
              BrowserLaunchBuilder.validatedStartURL(request.startURL) != nil,
              request.proxy?.isValid != false else { throw NeAntikError.invalidProfile }
        return BrowserProfile(name: request.name,
                              tags: [request.purpose.defaultTag],
                              startURL: request.startURL,
                              proxy: request.proxy,
                              createdAt: now,
                              updatedAt: now)
    }
}

/// A stable, inspectable contract for the values that must agree before a
/// profile is launched. It intentionally contains no secrets or raw IP data.
struct IdentityContract: Codable, Equatable, Sendable {
    let profileID: UUID
    let proxyKind: ProxyKind?
    let timezoneIdentifier: String?
    let localeIdentifier: String?
    let geolocationSource: String?
    let screenWidth: Int?
    let screenHeight: Int?
    let webRTCMode: String
    let deviceTupleID: String

    static func derive(from profile: BrowserProfile,
                       screenSize: (width: Int, height: Int)? = nil,
                       geolocationSource: String? = nil,
                       webRTCMode: String = "proxy-bound") -> IdentityContract {
        IdentityContract(profileID: profile.id,
                         proxyKind: profile.proxy?.kind,
                         timezoneIdentifier: profile.identity.timezoneIdentifier,
                         localeIdentifier: profile.identity.localeIdentifier,
                         geolocationSource: geolocationSource,
                         screenWidth: screenSize?.width,
                         screenHeight: screenSize?.height,
                         webRTCMode: webRTCMode,
                         deviceTupleID: profile.identity.deviceTupleID)
    }

    var issues: [String] {
        var result: [String] = []
        // Auto values are resolved from the host when the user leaves them
        // untouched; an absent optional screen override is therefore valid.
        if timezoneIdentifier?.isEmpty != false { result.append("Часовой пояс не определён") }
        if localeIdentifier?.isEmpty != false { result.append("Язык не определён") }
        if screenWidth == nil || screenHeight == nil {
            result.append("Размер экрана не определён")
        }
        if webRTCMode.isEmpty { result.append("WebRTC не настроен") }
        return result
    }
}

enum ProfileReadinessStatus: String, Codable, Sendable { case ready, attention, checkRequired }

struct ProfileReadinessReport: Codable, Equatable, Sendable {
    let status: ProfileReadinessStatus
    let issues: [String]
    let checkedAt: Date

    static func evaluate(profile: BrowserProfile, proxyReady: Bool? = nil,
                         runtimeReady: Bool = true, now: Date = Date()) -> Self {
        // Host locale and timezone are automatic defaults when the profile
        // does not override them; they are not launch blockers.
        var issues = IdentityContract.derive(from: profile).issues.filter { issue in
            // Host locale, timezone and display geometry are automatic defaults.
            // A window can start before AppKit reports a display, so none of
            // these host-derived values may block a normal profile launch.
            !issue.contains("Часовой пояс") &&
                !issue.contains("Язык") &&
                !issue.contains("Размер экрана")
        }
        if profile.proxy != nil && proxyReady != true { issues.append("Прокси нужно проверить") }
        if !runtimeReady { issues.append("Версия Chromium требует проверки") }
        let status: ProfileReadinessStatus = issues.isEmpty ? .ready :
            (issues.contains { $0.contains("нужно") || $0.contains("требует") } ? .checkRequired : .attention)
        return Self(status: status, issues: issues, checkedAt: now)
    }
}

extension ProfileReadinessReport {
    var title: String {
        switch status {
        case .ready: "Готово"
        case .attention: "Есть проблема"
        case .checkRequired: "Нужна проверка"
        }
    }

    var systemImage: String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .checkRequired: "questionmark.circle.fill"
        }
    }

    /// The compact surface should present one decision at a time. Keep the
    /// full issue list for diagnostics, but expose a deterministic primary
    /// issue and the single next action used by launch errors and row details.
    var primaryIssue: String? { issues.first }

    var nextAction: String? {
        guard let issue = primaryIssue else { return nil }
        if issue.contains("Прокси") { return "Проверь подключение прокси в сведениях профиля." }
        if issue.contains("Chromium") { return "Проверь установленное ядро и повтори запуск." }
        if issue.contains("WebRTC") { return "Открой сведения профиля и проверь режим WebRTC." }
        if issue.contains("часовой пояс") { return "Выбери часовой пояс или оставь автоматический режим." }
        if issue.contains("Язык") { return "Выбери язык или оставь автоматический режим." }
        return "Открой сведения профиля и устрани указанную проблему."
    }

}

struct ProfileStabilityRecord: Codable, Equatable, Sendable {
    let profileID: UUID
    let observedAt: Date
    let revision: UInt64
    let proxyKind: ProxyKind?
    let deviceTupleID: String
    let tabCount: Int
    let cookieCount: Int?
    let fingerprintChanged: Bool
    /// These flags are deliberately booleans: the history must explain drift
    /// without persisting cookies, URLs, credentials, or a proxy endpoint.
    let proxyChanged: Bool
    let cookiesChanged: Bool
    let tabsChanged: Bool

    static func capture(profile: BrowserProfile, tabCount: Int = 0,
                        cookieCount: Int? = nil, previous: Self? = nil,
                        now: Date = Date()) -> Self {
        let safeTabCount = max(0, tabCount)
        let proxyToken = profile.proxy.map { proxy in
            SHA256.hash(data: Data("\(proxy.kind.rawValue)|\(proxy.host)|\(proxy.port)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        return Self(profileID: profile.id, observedAt: now, revision: profile.revision,
             proxyKind: profile.proxy?.kind, deviceTupleID: profile.identity.deviceTupleID,
             tabCount: safeTabCount, cookieCount: cookieCount.map { max(0, $0) }, fingerprintChanged: previous.map {
                 $0.deviceTupleID != profile.identity.deviceTupleID
             } ?? false,
             proxyChanged: previous.map { $0.proxyToken != proxyToken } ?? false,
             cookiesChanged: previous.map {
                 cookieCount != nil && $0.cookieCount != nil && $0.cookieCount != cookieCount
             } ?? false,
             tabsChanged: previous.map { $0.tabCount != safeTabCount } ?? false,
             proxyToken: proxyToken)
    }

    private enum CodingKeys: String, CodingKey {
        case profileID, observedAt, revision, proxyKind, deviceTupleID,
             tabCount, cookieCount, proxyToken, fingerprintChanged, proxyChanged, cookiesChanged, tabsChanged
    }

    private init(profileID: UUID, observedAt: Date, revision: UInt64,
                 proxyKind: ProxyKind?, deviceTupleID: String, tabCount: Int,
                 cookieCount: Int?, fingerprintChanged: Bool,
                 proxyChanged: Bool, cookiesChanged: Bool, tabsChanged: Bool,
                 proxyToken: String?) {
        self.profileID = profileID
        self.observedAt = observedAt
        self.revision = revision
        self.proxyKind = proxyKind
        self.deviceTupleID = deviceTupleID
        self.tabCount = tabCount
        self.cookieCount = cookieCount
        self.fingerprintChanged = fingerprintChanged
        self.proxyChanged = proxyChanged
        self.cookiesChanged = cookiesChanged
        self.tabsChanged = tabsChanged
        self.proxyToken = proxyToken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try c.decode(UUID.self, forKey: .profileID)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        revision = try c.decode(UInt64.self, forKey: .revision)
        proxyKind = try c.decodeIfPresent(ProxyKind.self, forKey: .proxyKind)
        deviceTupleID = try c.decode(String.self, forKey: .deviceTupleID)
        tabCount = max(0, try c.decode(Int.self, forKey: .tabCount))
        cookieCount = try c.decodeIfPresent(Int.self, forKey: .cookieCount).map { max(0, $0) }
        proxyToken = try c.decodeIfPresent(String.self, forKey: .proxyToken)
        fingerprintChanged = try c.decodeIfPresent(Bool.self, forKey: .fingerprintChanged) ?? false
        proxyChanged = try c.decodeIfPresent(Bool.self, forKey: .proxyChanged) ?? false
        cookiesChanged = try c.decodeIfPresent(Bool.self, forKey: .cookiesChanged) ?? false
        tabsChanged = try c.decodeIfPresent(Bool.self, forKey: .tabsChanged) ?? false
    }

    private let proxyToken: String?
}

/// Small bounded history, persisted as one atomically replaced JSON file.
struct ProfileStabilityHistoryStore: Sendable {
    let fileURL: URL
    let maximumRecords = 20

    init(rootDirectory: URL) { fileURL = rootDirectory.appendingPathComponent("profile-stability.json") }

    func records(for profileID: UUID) -> [ProfileStabilityRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? decoder.decode([ProfileStabilityRecord].self, from: data)
        else { return [] }
        return all.filter { $0.profileID == profileID }.sorted { $0.observedAt > $1.observedAt }
    }

    func append(_ record: ProfileStabilityRecord) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var all = (try? decoder.decode([ProfileStabilityRecord].self,
                                       from: Data(contentsOf: fileURL))) ?? []
        all.removeAll { $0.profileID == record.profileID && $0.observedAt == record.observedAt }
        all.append(record)
        // Retain a useful window for every profile. A global cap would let a
        // noisy profile evict the history of all other workspaces.
        let limited = all
            .groupedByProfileHistory(maximumRecords: maximumRecords)
        let data = try JSONEncoder.neantikStable.encode(limited)
        let temporary = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: temporary, options: .completeFileProtection)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                _ = try FileManager.default.replaceItemAt(
                    fileURL, withItemAt: temporary, backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } catch {
                // A few temporary/APFS locations reject replacement. Preserve
                // the last good JSON and retry with a clean move.
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private extension Array where Element == ProfileStabilityRecord {
    func groupedByProfileHistory(maximumRecords: Int) -> [Element] {
        Dictionary(grouping: self, by: \.profileID)
            .values
            .flatMap { $0.sorted { $0.observedAt > $1.observedAt }.prefix(maximumRecords) }
            .sorted { $0.observedAt > $1.observedAt }
    }
}

/// Snapshot copies are written beside the profile, then atomically renamed so
/// a crash can never expose a half-copied BrowserData directory.
struct AtomicProfileSnapshotStore: Sendable {
    struct Metadata: Codable {
        let profileID: UUID
        let runtimeVersion: String?
    }
    let root: URL
    init(rootDirectory: URL) { root = rootDirectory.appendingPathComponent("Snapshots", isDirectory: true) }

    @discardableResult
    func create(profileID: UUID, browserData: URL, now: Date = Date(), runtimeVersion: String? = nil) throws -> URL {
        if let runtimeVersion, ChromiumCompatibilityCoordinator.versionParts(runtimeVersion) == nil {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let folder = root.appendingPathComponent(profileID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appendingPathComponent("\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)", isDirectory: true)
        let temporary = folder.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: browserData, to: temporary)
        let metadata = final.appendingPathExtension("json")
        do {
            try JSONEncoder().encode(Metadata(profileID: profileID, runtimeVersion: runtimeVersion))
                .write(to: metadata, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try FileManager.default.moveItem(at: temporary, to: final)
        return final
    }

    /// Returns snapshots newest first. Hidden temporary copies are ignored.
    func snapshots(for profileID: UUID) -> [URL] {
        let folder = root.appendingPathComponent(profileID.uuidString, isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left > right
        } ?? []
    }

    /// Replaces browser data only after a complete staged copy exists.
    /// The existing directory is retained as a sibling rollback copy until
    /// the replacement is safely moved into place.
    func validatedRuntimeVersion(snapshot: URL, profileID: UUID? = nil) throws -> String? {
        let values = try snapshot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              snapshot.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if let profileID {
            let owner = root.appendingPathComponent(profileID.uuidString, isDirectory: true)
            guard (try owner.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                  snapshot.deletingLastPathComponent().standardizedFileURL == owner.standardizedFileURL,
                  snapshot.resolvingSymlinksInPath().deletingLastPathComponent() == owner.resolvingSymlinksInPath()
            else { throw CocoaError(.fileReadNoPermission) }
        }
        let metadataURL = snapshot.appendingPathExtension("json")
        var restoredVersion: String?
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            guard (try metadataURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])).isSymbolicLink != true,
                  (try metadataURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
            else { throw CocoaError(.fileReadNoPermission) }
            let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
            guard metadata.profileID.uuidString == snapshot.deletingLastPathComponent().lastPathComponent,
                  metadata.runtimeVersion == nil || ChromiumCompatibilityCoordinator.versionParts(metadata.runtimeVersion!) != nil
            else { throw CocoaError(.fileReadCorruptFile) }
            restoredVersion = metadata.runtimeVersion
        }
        return restoredVersion
    }

    @discardableResult
    func restore(snapshot: URL, to browserData: URL, profileID: UUID? = nil,
                 requireKnownVersion: Bool = false) throws -> String? {
        let restoredVersion = try validatedRuntimeVersion(snapshot: snapshot, profileID: profileID)
        if requireKnownVersion && restoredVersion == nil {
            throw CocoaError(.fileReadCorruptFile)
        }
        let parent = browserData.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: snapshot, to: staged)
        let previous = parent.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: browserData.path) {
            try FileManager.default.moveItem(at: browserData, to: previous)
        }
        do {
            try FileManager.default.moveItem(at: staged, to: browserData)
            try? FileManager.default.removeItem(at: previous)
        } catch {
            try? FileManager.default.removeItem(at: browserData)
            if FileManager.default.fileExists(atPath: previous.path) {
                try? FileManager.default.moveItem(at: previous, to: browserData)
            }
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return restoredVersion
    }
}

enum ChromiumCompatibilityDecision: Equatable, Sendable { case compatible, migrate, rollbackRequired }

enum ChromiumCompatibilityChecker {
    static func decision(previousVersion: String?, current: BrowserRuntime,
                         profileDataExists: Bool) -> ChromiumCompatibilityDecision {
        guard profileDataExists else { return .rollbackRequired }
        guard let previousVersion, let currentVersion = current.inspection.version,
              !previousVersion.isEmpty, !currentVersion.isEmpty else { return .migrate }
        return previousVersion == currentVersion ? .compatible : .migrate
    }
}

/// Records the runtime that last opened each profile and applies the safe
/// compatibility rule at the process boundary. Chromium can migrate its
/// on-disk format when the bundled version changes, so a migration is only
/// allowed when the existing profile directory is present and a snapshot was
/// captured immediately before launch. A missing directory for a previously
/// opened profile is blocked rather than silently creating a new identity.
struct ChromiumCompatibilityCoordinator: Sendable {
    struct Marker: Codable, Equatable, Sendable {
        let profileID: UUID
        let runtimeVersion: String
        let recordedAt: Date
        var emptyProfileLaunchPending: Bool? = nil
        var restorationPending: Bool? = nil
    }

    enum Action: Equatable, Sendable {
        case firstLaunch
        case compatible
        case migrate
        case rollbackRequired
    }

    let markerURL: URL

    init(rootDirectory: URL) {
        markerURL = rootDirectory.appendingPathComponent("chromium-compatibility.json")
    }

    func action(for profileID: UUID, runtimeVersion: String?, profileDataExists: Bool,
                snapshotAvailable: Bool) -> Action {
        guard let runtimeVersion, Self.versionParts(runtimeVersion) != nil else {
            return .rollbackRequired
        }
        guard let recorded = try? markers() else { return .rollbackRequired }
        guard recorded[profileID]?.restorationPending != true else { return .rollbackRequired }
        let previous = recorded[profileID]?.runtimeVersion
        guard previous != nil else { return .firstLaunch }
        guard profileDataExists else {
            // Only a reserved first launch may retry without a data directory.
            // Existing/legacy profiles with missing data still require recovery.
            return previous == runtimeVersion && recorded[profileID]?.emptyProfileLaunchPending == true
                ? .firstLaunch : .rollbackRequired
        }
        guard previous == runtimeVersion else {
            // A snapshot of migrated data does not make it safe for an older
            // runtime. Restore a compatible pre-upgrade snapshot first.
            guard let previous,
                  Self.versionParts(previous) != nil,
                  Self.versionParts(runtimeVersion) != nil,
                  previous.compare(runtimeVersion, options: .numeric) == .orderedAscending
            else { return .rollbackRequired }
            return snapshotAvailable ? .migrate : .rollbackRequired
        }
        return .compatible
    }

    fileprivate static func versionParts(_ version: String) -> [UInt]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) })
        else { return nil }
        let numbers = parts.compactMap { UInt($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    func recordedVersion(for profileID: UUID) throws -> String? {
        let marker = try markers()[profileID]
        // Interrupted restoration may have replaced the data, so its previous
        // version must not label a newly captured recovery snapshot.
        return marker?.restorationPending == true ? nil : marker?.runtimeVersion
    }

    /// Reserves the version before Chromium is allowed to mutate profile data.
    /// A failed launch must not roll it back: the child may have started.
    /// Preserve corrupt evidence instead of silently discarding other profiles.
    func record(profileID: UUID, runtimeVersion: String?, now: Date = Date(),
                emptyProfileLaunchPending: Bool = false,
                restorationPending: Bool = false) throws {
        guard let runtimeVersion, Self.versionParts(runtimeVersion) != nil else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var values = try markers()
        values[profileID] = Marker(profileID: profileID, runtimeVersion: runtimeVersion,
                                  recordedAt: now, emptyProfileLaunchPending: emptyProfileLaunchPending,
                                  restorationPending: restorationPending)
        let data = try JSONEncoder.neantikStable.encode(Array(values.values).sorted { $0.profileID.uuidString < $1.profileID.uuidString })
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = markerURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                _ = try FileManager.default.replaceItemAt(markerURL, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: temporary, to: markerURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func markers() throws -> [UUID: Marker] {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return [:] }
        let data = try Data(contentsOf: markerURL)
        let values = try JSONDecoder.neantikStable.decode([Marker].self, from: data)
        var result: [UUID: Marker] = [:]
        for marker in values {
            guard Self.versionParts(marker.runtimeVersion) != nil,
                  result.updateValue(marker, forKey: marker.profileID) == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return result
    }
}

extension JSONEncoder {
    static var neantikStable: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}

extension JSONDecoder {
    static var neantikStable: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
