import Foundation

/// Independent compiled record for the preserved six-layer signed font runtime.
/// Source presence is not release qualification; downloaded metadata cannot amend pins.
package enum DirectUpdateFontRuntimePins {
    package static let runtimeDigest = "f0bd944a15e57476f7f2d78ea8df8f743dd9d7dbd1647c69c8e89d5754485b80"
    package static let evidenceDigest = "dd2804eff2ebf60cccf1e99a072837278814bd1a13e6c6110014785517dd0d19"
    package static let reportDigest = "534900f801963f79dfc2e0b7fc9c693c4a06c6b06d9bb34392c59526c53df885"
    package static let runtimeEntries = 948, evidenceEntries = 141
    package static let runtimeBytes: Int64 = 411230673, evidenceBytes: Int64 = 51997130
    package static let createdAt = "2026-10-15T23:00:15.779363Z"
    package static let argsDigest = "428054a30abeb212aa3784f524bb27ef4bc0068ab7ebef149866b2b8bff30a3c"
    package static let executableDigest = "27d0378671dd946f2b19c518f928a60a44b19ae0f97552569adb3eecc7e95c6c"
    package static let frameworkDigest = "7bfe8e081bd94ea222e2a9ed304a56ef96a7edf342f12ecf079abf147c4b95f8"
    package static let reportHashes: [String: String] = [
        "appleDeviceTuplesManifestSHA256": "3c355a6a6708386c410c98cb9310a6f6e62ea5da065eb0faf0290b2a4a4ff6f2",
        "baseFullFDObservationSHA256": "d6836d97a7a24d370663976063516306bfc646c826149f579a319fdb5578722c",
        "candidateLockSHA256": "4e9b200c4ff32cc051e70b51a42919b4972ca20612a07abe73fdb6143f7fc671",
        "neantikPatchManifestSHA256": "c79ee59b55b1ad474229313660c31c19fcc3b67051bca4f1da1e6098b0b69748",
        "postbuildFullFDObservationSHA256": "11965553ae0535091f130a7caac97ed107ef99fd0980903847b2f708defe35e0",
        "securityBaselineSHA256": "5d79904022fa2f5b7658fd02e16216f54c926ae7d0bad6e77233f4a8fc11aa3f",
        "sourceContractSHA256": "e0eea87dd2bfbaa8561d199f89f366c02238df252666dad37cb4ff61d98d5f4b",
        "sourceDeltaProofSHA256": "8a86c02e8727790658626c501219a3c2f5b384372eee7e1e1d3c524a462844dc",
        "sourceLockSHA256": "4e9b200c4ff32cc051e70b51a42919b4972ca20612a07abe73fdb6143f7fc671",
        "sourceProvenanceSHA256": "108ae7176f5db22a37803c290c1031582b56cdefaaae593d0c76befb78c398d4",
    ]
}

/// A complete record is selected only by actual closure + captured report bytes.
package enum DirectUpdateRuntimeRecord: Sendable, Equatable, CaseIterable {
    case final9, fontSystemV1, fontSystemSecurity20261015V1, componentCompletionV1

    private struct RecordData: Sendable {
        let runtimeDigest: String
        let evidenceDigest: String
        let reportDigest: String
        let runtimeEntries: Int
        let evidenceEntries: Int
        let runtimeBytes: Int64
        let evidenceBytes: Int64
        let reportHashes: [String: String]
        let sourceMode: String
        let createdAt: String
        let argsDigest: String
        let executableDigest: String
        let frameworkDigest: String
        let sourceVariant: String?
    }

    private var data: RecordData {
        switch self {
        case .final9:
            RecordData(
                runtimeDigest: DirectUpdateRuntimePins.runtimeDigest,
                evidenceDigest: DirectUpdateRuntimePins.evidenceDigest,
                reportDigest: DirectUpdateRuntimePins.reportDigest,
                runtimeEntries: DirectUpdateRuntimePins.runtimeEntries,
                evidenceEntries: DirectUpdateRuntimePins.evidenceEntries,
                runtimeBytes: DirectUpdateRuntimePins.runtimeBytes,
                evidenceBytes: DirectUpdateRuntimePins.evidenceBytes,
                reportHashes: DirectUpdateRuntimePins.reportHashes,
                sourceMode: "executed-final9-preserved-build-and-current-packaging-inputs",
                createdAt: "2026-10-10T07:09:29.793627Z",
                argsDigest: "b32623308042c6b3b86f14ce9635ccc9abdc290148ce596c1e4f4a43ffde9a01",
                executableDigest: "1b1e460981efe56aa8f4825b7f4f7c6f2e8cc51e244d718ba300db78ac872ff0",
                frameworkDigest: "87374f1072a83850ea20da83897eac86de6d1357abcff0f0fad87dabd836e815",
                sourceVariant: nil
            )
        case .fontSystemV1:
            RecordData(
                runtimeDigest: DirectUpdateFontRuntimePins.runtimeDigest,
                evidenceDigest: DirectUpdateFontRuntimePins.evidenceDigest,
                reportDigest: DirectUpdateFontRuntimePins.reportDigest,
                runtimeEntries: DirectUpdateFontRuntimePins.runtimeEntries,
                evidenceEntries: DirectUpdateFontRuntimePins.evidenceEntries,
                runtimeBytes: DirectUpdateFontRuntimePins.runtimeBytes,
                evidenceBytes: DirectUpdateFontRuntimePins.evidenceBytes,
                reportHashes: DirectUpdateFontRuntimePins.reportHashes,
                sourceMode: "executed-font-system-v1-preserved-build-and-postbuild-fd-source-proof",
                createdAt: DirectUpdateFontRuntimePins.createdAt,
                argsDigest: DirectUpdateFontRuntimePins.argsDigest,
                executableDigest: DirectUpdateFontRuntimePins.executableDigest,
                frameworkDigest: DirectUpdateFontRuntimePins.frameworkDigest,
                sourceVariant: "font-system-v1"
            )
        case .fontSystemSecurity20261015V1:
            RecordData(
                runtimeDigest: DirectUpdateSecurityRuntimePins.runtimeDigest,
                evidenceDigest: DirectUpdateSecurityRuntimePins.evidenceDigest,
                reportDigest: DirectUpdateSecurityRuntimePins.reportDigest,
                runtimeEntries: DirectUpdateSecurityRuntimePins.runtimeEntries,
                evidenceEntries: DirectUpdateSecurityRuntimePins.evidenceEntries,
                runtimeBytes: DirectUpdateSecurityRuntimePins.runtimeBytes,
                evidenceBytes: DirectUpdateSecurityRuntimePins.evidenceBytes,
                reportHashes: DirectUpdateSecurityRuntimePins.reportHashes,
                sourceMode: "executed-security-backport-preserved-build-and-postbuild-fd-source-proof",
                createdAt: DirectUpdateSecurityRuntimePins.createdAt,
                argsDigest: DirectUpdateSecurityRuntimePins.argsDigest,
                executableDigest: DirectUpdateSecurityRuntimePins.executableDigest,
                frameworkDigest: DirectUpdateSecurityRuntimePins.frameworkDigest,
                sourceVariant: "font-system-security-20261015-v1"
            )
        case .componentCompletionV1:
            RecordData(
                runtimeDigest: DirectUpdateComponentRuntimePins.runtimeDigest,
                evidenceDigest: DirectUpdateComponentRuntimePins.evidenceDigest,
                reportDigest: DirectUpdateComponentRuntimePins.reportDigest,
                runtimeEntries: DirectUpdateComponentRuntimePins.runtimeEntries,
                evidenceEntries: DirectUpdateComponentRuntimePins.evidenceEntries,
                runtimeBytes: DirectUpdateComponentRuntimePins.runtimeBytes,
                evidenceBytes: DirectUpdateComponentRuntimePins.evidenceBytes,
                reportHashes: DirectUpdateComponentRuntimePins.reportHashes,
                sourceMode: "executed-component-completion-preserved-build-and-postbuild-fd-source-proof",
                createdAt: DirectUpdateComponentRuntimePins.createdAt,
                argsDigest: DirectUpdateComponentRuntimePins.argsDigest,
                executableDigest: DirectUpdateComponentRuntimePins.executableDigest,
                frameworkDigest: DirectUpdateComponentRuntimePins.frameworkDigest,
                sourceVariant: "component-completion-v1"
            )
        }
    }

    package var runtimeDigest: String { data.runtimeDigest }
    package var evidenceDigest: String { data.evidenceDigest }
    package var reportDigest: String { data.reportDigest }
    package var runtimeEntries: Int { data.runtimeEntries }
    package var evidenceEntries: Int { data.evidenceEntries }
    package var runtimeBytes: Int64 { data.runtimeBytes }
    package var evidenceBytes: Int64 { data.evidenceBytes }
    package var reportHashes: [String: String] { data.reportHashes }
    package var sourceMode: String { data.sourceMode }
    package var createdAt: String { data.createdAt }
    package var argsDigest: String { data.argsDigest }
    package var executableDigest: String { data.executableDigest }
    package var frameworkDigest: String { data.frameworkDigest }
    package var sourceVariant: String? { data.sourceVariant }
    package static var maximumRuntimeEntries: Int { allCases.map(\.runtimeEntries).max()! }
    package static var maximumEvidenceEntries: Int { allCases.map(\.evidenceEntries).max()! }
    package static var maximumRuntimeBytes: Int64 { allCases.map(\.runtimeBytes).max()! }
    package static var maximumEvidenceBytes: Int64 { allCases.map(\.evidenceBytes).max()! }
}
