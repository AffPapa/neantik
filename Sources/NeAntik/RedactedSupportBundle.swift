import Foundation

struct RedactedSupportBundle: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    enum RuntimeStatus: String, Codable, Sendable {
        case ready
        case attention
        case unavailable
        case unknown
    }

    enum SignatureStatus: String, Codable, Sendable {
        case valid
        case invalid
        case unverified
        case unknown
    }

    struct Manager: Codable, Equatable, Sendable {
        let version: String
        let build: String
    }

    struct Runtime: Codable, Equatable, Sendable {
        let status: RuntimeStatus
        let version: String?
        let architecture: String
        let signature: SignatureStatus
        let executableHash: String?
        let frameworkHash: String?
    }

    struct Workspace: Codable, Equatable, Sendable {
        let profileCount: Int
        let activeProfileCount: Int
        let archivedProfileCount: Int
        let folderCount: Int
    }

    struct Health: Codable, Equatable, Sendable {
        let failureCount: Int
        let attentionCount: Int
        let recoveryCount: Int
    }

    struct Check: Codable, Equatable, Sendable {
        let id: String
        let status: SupportCheckStatus
    }

    enum SupportCheckStatus: String, Codable, Sendable {
        case verified
        case partial
        case failed
        case blocked
        case unverified
    }

    struct Performance: Codable, Equatable, Sendable {
        let managerStatus: SupportCheckStatus
        let runtimeStatus: SupportCheckStatus
    }

    let schemaVersion: Int
    let generatedAt: Date
    let manager: Manager
    let runtime: Runtime
    let workspace: Workspace
    let health: Health
    let checks: [Check]
    let performance: Performance

    init(
        managerVersion: String?,
        managerBuild: String?,
        runtime: BrowserRuntime?,
        runtimeAvailability: BrowserRuntimeAvailability,
        profiles: [BrowserProfile],
        folderCount: Int,
        processStates: [BrowserProfileProcessState],
        generatedAt: Date = Date()
    ) throws {
        guard let managerVersion,
              Self.isVersion(managerVersion),
              let managerBuild,
              Self.isBuild(managerBuild)
        else {
            throw RedactedSupportBundleError.managerMetadataUnavailable
        }
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RedactedSupportBundleError.invalidDate
        }
        guard folderCount >= 0,
              folderCount <= ProfileStorageLimits.maximumProfileCount,
              profiles.count <= ProfileStorageLimits.maximumProfileCount,
              processStates.count == profiles.count
        else {
            throw RedactedSupportBundleError.inconsistentWorkspace
        }

        let inspection = runtime?.inspection
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.manager = Manager(
            version: managerVersion,
            build: managerBuild
        )
        self.runtime = Runtime(
            status: Self.runtimeStatus(for: runtimeAvailability),
            version: inspection?.version,
            architecture:
                inspection?.architectures.contains("arm64") == true
                ? "arm64"
                : "unknown",
            signature: Self.signatureStatus(
                inspection?.codeSignatureValid
            ),
            executableHash: Self.validHash(inspection?.executableSHA256),
            frameworkHash: Self.validHash(inspection?.frameworkSHA256)
        )
        let activeCount = profiles.lazy.filter { !$0.isArchived }.count
        self.workspace = Workspace(
            profileCount: profiles.count,
            activeProfileCount: activeCount,
            archivedProfileCount: profiles.count - activeCount,
            folderCount: folderCount
        )
        let recoveryCount = processStates.count {
            $0 == .recoveryRequired
        }
        let attentionCount = processStates.count {
            switch $0 {
            case .checking, .externalManualOnly, .externalUnverified:
                true
            case .stopped, .managed, .externalVerified, .recoveryRequired:
                false
            }
        }
        self.health = Health(
            failureCount: recoveryCount,
            attentionCount: attentionCount,
            recoveryCount: recoveryCount
        )
        self.checks = []
        self.performance = Performance(
            managerStatus: .unverified,
            runtimeStatus: .unverified
        )
    }

    private static func runtimeStatus(
        for availability: BrowserRuntimeAvailability
    ) -> RuntimeStatus {
        switch availability {
        case .ready:
            .ready
        case .invalid:
            .attention
        case .missing:
            .unavailable
        case .resolving:
            .unknown
        }
    }

    private static func signatureStatus(
        _ value: Bool?
    ) -> SignatureStatus {
        switch value {
        case .some(true):
            .valid
        case .some(false):
            .invalid
        case .none:
            .unknown
        }
    }

    private static func isVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".")
        return (3...4).contains(components.count) &&
            components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isBuild(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 12 && value.allSatisfy(\.isNumber)
    }

    private static func validHash(_ value: String?) -> String? {
        guard let value,
              value.count == 64,
              value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            return nil
        }
        return value
    }
}

enum RedactedSupportBundleError: LocalizedError, Equatable, Sendable {
    case managerMetadataUnavailable
    case invalidDate
    case inconsistentWorkspace
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .managerMetadataUnavailable:
            "Не удалось безопасно определить версию NeAntik."
        case .invalidDate:
            "Диагностика содержит некорректную дату."
        case .inconsistentWorkspace:
            "Состояние рабочего пространства изменилось во время экспорта."
        case .fileTooLarge:
            "Файл диагностики превысил безопасный размер."
        }
    }
}
