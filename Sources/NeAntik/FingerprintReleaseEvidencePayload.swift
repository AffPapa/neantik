import Foundation

enum FingerprintEvidenceReleaseChannel:
    String, Codable, Equatable, Sendable
{
    case publicAlpha = "public-alpha"
    case production
}

enum FingerprintReleaseCriticalSurfaceState:
    String, Codable, Equatable, Sendable
{
    case unavailable
    case unstable
    case stableSame = "stable-same"
    case stableDifferent = "stable-different"
}

struct FingerprintReleaseEvidencePayload:
    Codable, Equatable, Sendable
{
    static let currentSchemaVersion = 1
    static let kindName = "neantik-fingerprint-release-result"

    let schemaVersion: Int
    let kind: String
    let createdAt: Date
    let releaseChannel: FingerprintEvidenceReleaseChannel
    let managerVersion: String
    let managerBuild: String
    let runtimeName: String
    let runtimeVersion: String
    let runtimeFlavor: String
    let runtimeCodeSignatureValid: Bool
    let runtimeExecutableSHA256: String
    let runtimeFrameworkSHA256: String
    let auditSchemaVersion: Int
    let identityCatalogVersion: Int
    let executionMode: String
    let verdict: String
    let criticalSurfaces:
        [String: FingerprintReleaseCriticalSurfaceState]
    let changedCriticalKeys: [String]
    let unavailableRequiredKeys: [String]
    let unstableRequiredKeys: [String]
    let profileSequenceValid: Bool
    let identitySequenceValid: Bool
    let crossRealmConsistent: Bool
    let deviceTupleConsistent: Bool
    let networkPrivacyControlled: Bool
    let publicAlphaQualified: Bool
    let productionQualified: Bool
    let limitations: [String]

    init(
        report: FingerprintAuditReport,
        releaseChannel: FingerprintEvidenceReleaseChannel
    ) throws {
        guard let managerVersion = report.managerVersion,
              let managerBuild = report.managerBuild,
              let runtimeVersion = report.runtimeVersion,
              report.runtimeCodeSignatureValid == true,
              let runtimeExecutableSHA256 =
                report.runtimeExecutableSHA256,
              let runtimeFrameworkSHA256 =
                report.runtimeFrameworkSHA256,
              let identityCatalogVersion =
                report.identityCatalogVersion,
              report.executionMode == .browser
        else {
            throw FingerprintEvidenceReleaseError
                .candidateMetadataMismatch
        }

        schemaVersion = Self.currentSchemaVersion
        kind = Self.kindName
        createdAt = report.createdAt
        self.releaseChannel = releaseChannel
        self.managerVersion = managerVersion
        self.managerBuild = managerBuild
        runtimeName = report.runtimeName
        self.runtimeVersion = runtimeVersion
        runtimeFlavor = report.runtimeFlavor.rawValue
        runtimeCodeSignatureValid = true
        self.runtimeExecutableSHA256 = runtimeExecutableSHA256
        self.runtimeFrameworkSHA256 = runtimeFrameworkSHA256
        auditSchemaVersion = report.effectiveAuditSchemaVersion
        self.identityCatalogVersion = identityCatalogVersion
        executionMode = FingerprintAuditExecutionMode.browser.rawValue
        verdict = report.verdict.rawValue
        criticalSurfaces = Dictionary(
            uniqueKeysWithValues:
                FingerprintAuditReport.criticalKeys.map {
                    (
                        $0,
                        Self.surfaceState($0, report: report)
                    )
                }
        )
        changedCriticalKeys = report.changedCriticalKeys.sorted()

        let requiredKeys = Array(
            Set(
                FingerprintAuditReport.criticalKeys +
                    FingerprintAuditReport
                        .publicAlphaStableContextKeys +
                    FingerprintAuditReport
                        .productionExtendedContextKeys
            )
        ).sorted()
        unavailableRequiredKeys = requiredKeys.filter {
            !Self.isAvailable(report.firstInitial.values[$0]) ||
                !Self.isAvailable(report.second.values[$0]) ||
                !Self.isAvailable(report.firstRepeat.values[$0])
        }
        unstableRequiredKeys = requiredKeys.filter {
            report.firstInitial.values[$0] !=
                report.firstRepeat.values[$0]
        }
        profileSequenceValid =
            report.firstInitial.profileID != report.second.profileID &&
            report.firstInitial.profileID ==
                report.firstRepeat.profileID
        identitySequenceValid =
            report.firstInitial.identityCode !=
                report.second.identityCode &&
            report.firstInitial.identityCode ==
                report.firstRepeat.identityCode
        crossRealmConsistent =
            report.crossRealmConsistencyIssues.isEmpty
        deviceTupleConsistent =
            report.deviceTupleConsistencyIssues.isEmpty
        networkPrivacyControlled =
            report.networkPrivacyIssues.isEmpty &&
            report.webrtcDirectControl != nil
        publicAlphaQualified =
            report.isPublicAlphaReleaseQualified
        productionQualified =
            report.isProductionReleaseQualified
        limitations =
            publicAlphaQualified && !productionQualified
            ? ["strict-coherence-not-qualified"]
            : []

        let channelQualified = switch releaseChannel {
        case .publicAlpha:
            publicAlphaQualified
        case .production:
            productionQualified
        }
        guard channelQualified else {
            throw FingerprintEvidenceReleaseError
                .reportNotQualified
        }
    }

    func encodedCanonical() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        return try encoder.encode(self)
    }

    private static func surfaceState(
        _ key: String,
        report: FingerprintAuditReport
    ) -> FingerprintReleaseCriticalSurfaceState {
        let first = report.firstInitial.values[key]
        let second = report.second.values[key]
        let repeatValue = report.firstRepeat.values[key]
        guard isAvailable(first),
              isAvailable(second),
              isAvailable(repeatValue)
        else {
            return .unavailable
        }
        guard first == repeatValue else {
            return .unstable
        }
        return first == second ? .stableSame : .stableDifferent
    }

    private static func isAvailable(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value != "unavailable"
    }
}
