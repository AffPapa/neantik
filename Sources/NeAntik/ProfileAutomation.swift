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
        if timezoneIdentifier == nil { result.append("Часовой пояс не определён") }
        if localeIdentifier == nil { result.append("Язык не определён") }
        if screenWidth == nil || screenHeight == nil { result.append("Размер экрана не определён") }
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
        var issues = IdentityContract.derive(from: profile).issues
        if profile.proxy != nil && proxyReady != true { issues.append("Прокси нужно проверить") }
        if !runtimeReady { issues.append("Версия Chromium требует проверки") }
        let status: ProfileReadinessStatus = issues.isEmpty ? .ready :
            (issues.contains { $0.contains("нужно") || $0.contains("требует") } ? .checkRequired : .attention)
        return Self(status: status, issues: issues, checkedAt: now)
    }
}

struct ProfileStabilityRecord: Codable, Equatable, Sendable {
    let profileID: UUID
    let observedAt: Date
    let revision: UInt64
    let proxyKind: ProxyKind?
    let deviceTupleID: String
    let tabCount: Int
    let fingerprintChanged: Bool

    static func capture(profile: BrowserProfile, tabCount: Int = 0,
                        previous: Self? = nil, now: Date = Date()) -> Self {
        Self(profileID: profile.id, observedAt: now, revision: profile.revision,
             proxyKind: profile.proxy?.kind, deviceTupleID: profile.identity.deviceTupleID,
             tabCount: max(0, tabCount), fingerprintChanged: previous.map {
                $0.deviceTupleID != profile.identity.deviceTupleID
            } ?? false)
    }
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
        all.sort { $0.observedAt > $1.observedAt }
        let limited = Array(all.prefix(maximumRecords))
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

/// Snapshot copies are written beside the profile, then atomically renamed so
/// a crash can never expose a half-copied BrowserData directory.
struct AtomicProfileSnapshotStore: Sendable {
    let root: URL
    init(rootDirectory: URL) { root = rootDirectory.appendingPathComponent("Snapshots", isDirectory: true) }

    @discardableResult
    func create(profileID: UUID, browserData: URL, now: Date = Date()) throws -> URL {
        let folder = root.appendingPathComponent(profileID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appendingPathComponent("\(Int(now.timeIntervalSince1970))-\(UUID().uuidString)", isDirectory: true)
        let temporary = folder.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: browserData, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: final)
        return final
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

private extension JSONEncoder {
    static var neantikStable: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
}
