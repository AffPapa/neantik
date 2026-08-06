import CryptoKit
import Darwin
import Foundation
import Security

struct FingerprintEvidenceReleaseRequest: Equatable, Sendable {
    let candidateManifestURL: URL
    let evidenceOutputURL: URL
}

enum FingerprintEvidenceReleaseLoadResult {
    case audit(FingerprintEvidenceReleaseContext)
    case recovered(URL)
}

enum FingerprintEvidenceReleaseError: LocalizedError, Equatable {
    case invalidManifest
    case unsafeManifest
    case candidateMetadataMismatch
    case reportNotQualified
    case challengeAlreadyConsumed
    case outputUnavailable
    case operationFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "Манифест подготовленного приложения повреждён."
        case .unsafeManifest:
            "Манифест подготовленного приложения небезопасен."
        case .candidateMetadataMismatch:
            "Отчёт не относится к этому подготовленному приложению."
        case .reportNotQualified:
            "Проверка не подходит для выбранного канала выпуска."
        case .challengeAlreadyConsumed:
            "Одноразовая проверка этого кандидата уже использована."
        case .outputUnavailable:
            "Не удалось безопасно подготовить файл подписанного отчёта."
        case let .operationFailed(code):
            "Не удалось подписать отчёт выпуска (код \(code))."
        }
    }
}

protocol FingerprintEvidenceChallengeClaiming: Sendable {
    func claim(identifier: String, requestDigest: Data) throws
    func claimedDigest(identifier: String) throws -> Data?
}

struct KeychainFingerprintEvidenceChallengeClaimStore:
    FingerprintEvidenceChallengeClaiming, @unchecked Sendable
{
    private static let service =
        "app.neantik.fingerprint-evidence.consumed-challenge.v1"
    private let addItem: ([String: Any]) -> OSStatus
    private let copyItem:
        ([String: Any]) -> (status: OSStatus, data: Data?)

    init(
        addItem: @escaping ([String: Any]) -> OSStatus = {
            SecItemAdd($0 as CFDictionary, nil)
        },
        copyItem: @escaping ([String: Any]) ->
            (status: OSStatus, data: Data?) = {
                var result: CFTypeRef?
                let status = SecItemCopyMatching(
                    $0 as CFDictionary,
                    &result
                )
                return (status, result as? Data)
        }
    ) {
        self.addItem = addItem
        self.copyItem = copyItem
    }

    func claim(identifier: String, requestDigest: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: requestDigest
        ]
        let status = addItem(query)
        if status == errSecDuplicateItem {
            throw FingerprintEvidenceReleaseError
                .challengeAlreadyConsumed
        }
        guard status == errSecSuccess else {
            throw FingerprintEvidenceReleaseError
                .operationFailed(Int(status))
        }
    }

    func claimedDigest(identifier: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let result = copyItem(query)
        if result.status == errSecItemNotFound {
            return nil
        }
        guard result.status == errSecSuccess,
              let data = result.data,
              data.count == 32
        else {
            throw FingerprintEvidenceReleaseError
                .operationFailed(Int(result.status))
        }
        return data
    }
}

struct FingerprintEvidenceCandidateMetadata: Equatable, Sendable {
    let releaseChannel: FingerprintEvidenceReleaseChannel
    let managerVersion: String
    let managerBuild: String
    let runtimeExecutableSHA256: String
    let runtimeFrameworkSHA256: String
}

final class FingerprintEvidenceReleaseContext {
    let request: FingerprintEvidenceReleaseRequest
    let candidateManifest: Data
    let metadata: FingerprintEvidenceCandidateMetadata

    private let binding: FingerprintEvidenceManifestBinding
    private let signerProvider:
        @Sendable () throws -> any FingerprintEvidenceSigning
    private let abandonAuthority: (UUID) throws -> Void
    private let claimStore: any FingerprintEvidenceChallengeClaiming
    private let recoveryStore: any FingerprintEvidenceRecoveryStoring
    private let output: any FingerprintEvidenceEnrollmentOutput
    private var attempted = false

    static func load(
        request: FingerprintEvidenceReleaseRequest,
        executableURL: URL,
        bundle: Bundle = .main,
        authority:
            SecureEnclaveFingerprintEvidenceAuthority =
                SecureEnclaveFingerprintEvidenceAuthority(),
        claimStore: any FingerprintEvidenceChallengeClaiming =
            KeychainFingerprintEvidenceChallengeClaimStore()
    ) throws -> FingerprintEvidenceReleaseLoadResult {
        let manifest = try readStableRegularFile(
            request.candidateManifestURL,
            maximumBytes:
                FingerprintEvidenceEnvelopeCodec.maximumManifestBytes
        )
        let parsed = try parseCandidateMetadata(manifest)
        guard parsed.metadata.managerVersion ==
                bundle.object(
                    forInfoDictionaryKey:
                        "CFBundleShortVersionString"
                ) as? String,
              parsed.metadata.managerBuild ==
                bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String
        else {
            throw FingerprintEvidenceReleaseError
                .candidateMetadataMismatch
        }
        let executable = try readStableRegularFile(
            executableURL,
            maximumBytes: 128 * 1_024 * 1_024
        )
        guard Self.hex(SHA256.hash(data: executable)) ==
                parsed.managerExecutableSHA256
        else {
            throw FingerprintEvidenceReleaseError
                .candidateMetadataMismatch
        }

        let binding =
            try FingerprintEvidenceEnvelopeCodec.manifestBinding(
                in: manifest
            )
        let validated = try binding.validated()
        let output: any FingerprintEvidenceEnrollmentOutput
        do {
            output =
                try AtomicFingerprintEvidenceReleaseOutput(
                    url: request.evidenceOutputURL,
                    allowIdenticalExisting: true
                )
        } catch {
            throw FingerprintEvidenceReleaseError.outputUnavailable
        }
        let context = FingerprintEvidenceReleaseContext(
            request: request,
            candidateManifest: manifest,
            metadata: parsed.metadata,
            binding: binding,
            signerProvider: {
                try authority.existingSigner(
                    sessionID: binding.sessionID,
                    expectedPublicKeyX963:
                        validated.publicKey.x963Representation
                )
            },
            abandonAuthority: {
                try authority.abandon(sessionID: $0)
            },
            claimStore: claimStore,
            recoveryStore:
                FileFingerprintEvidenceRecoveryStore(),
            output: output
        )
        if let recovered = try context.recoverPersistedEnvelope() {
            return .recovered(recovered)
        }
        return .audit(context)
    }

    convenience init(
        request: FingerprintEvidenceReleaseRequest,
        candidateManifest: Data,
        metadata: FingerprintEvidenceCandidateMetadata,
        binding: FingerprintEvidenceManifestBinding,
        signer: any FingerprintEvidenceSigning,
        abandonAuthority: @escaping (UUID) throws -> Void,
        claimStore: any FingerprintEvidenceChallengeClaiming,
        recoveryStore: any FingerprintEvidenceRecoveryStoring =
            DiscardingFingerprintEvidenceRecoveryStore(),
        output: any FingerprintEvidenceEnrollmentOutput
    ) {
        self.init(
            request: request,
            candidateManifest: candidateManifest,
            metadata: metadata,
            binding: binding,
            signerProvider: { signer },
            abandonAuthority: abandonAuthority,
            claimStore: claimStore,
            recoveryStore: recoveryStore,
            output: output
        )
    }

    init(
        request: FingerprintEvidenceReleaseRequest,
        candidateManifest: Data,
        metadata: FingerprintEvidenceCandidateMetadata,
        binding: FingerprintEvidenceManifestBinding,
        signerProvider:
            @escaping @Sendable () throws ->
                any FingerprintEvidenceSigning,
        abandonAuthority: @escaping (UUID) throws -> Void,
        claimStore: any FingerprintEvidenceChallengeClaiming,
        recoveryStore: any FingerprintEvidenceRecoveryStoring,
        output: any FingerprintEvidenceEnrollmentOutput
    ) {
        self.request = request
        self.candidateManifest = candidateManifest
        self.metadata = metadata
        self.binding = binding
        self.signerProvider = signerProvider
        self.abandonAuthority = abandonAuthority
        self.claimStore = claimStore
        self.recoveryStore = recoveryStore
        self.output = output
    }

    @discardableResult
    func persist(
        report: FingerprintAuditReport
    ) throws -> URL {
        guard !attempted else {
            throw FingerprintEvidenceReleaseError
                .challengeAlreadyConsumed
        }
        attempted = true
        if let recovered = try recoverPersistedEnvelope() {
            return recovered
        }
        try validateCandidateCoherence(report)
        let payload = try FingerprintReleaseEvidencePayload(
            report: report,
            releaseChannel: metadata.releaseChannel
        ).encodedCanonical()
        let requestDigest = SHA256.hash(
            data: candidateManifest + payload
        )
        let identifier = claimIdentifier()

        guard !output.hasExistingEntry else {
            throw FingerprintEvidenceReleaseError.outputUnavailable
        }
        try claimStore.claim(
            identifier: identifier,
            requestDigest: Data(requestDigest)
        )
        let envelopeData: Data
        do {
            let signer = try signerProvider()
            let envelope = try FingerprintEvidenceEnvelopeCodec.make(
                payload: payload,
                candidateManifest: candidateManifest,
                signer: signer
            )
            envelopeData =
                try FingerprintEvidenceEnvelopeCodec.encode(envelope)
            guard try FingerprintEvidenceEnvelopeCodec.verify(
                envelopeData,
                candidateManifest: candidateManifest
            ) == payload else {
                throw FingerprintEvidenceError.invalidSignature
            }

            // Persist the exact signed bytes before destroying the key.
            // Recovery publishes only these bytes and never signs again.
            try recoveryStore.storeEnvelope(
                envelopeData,
                identifier: identifier
            )
        } catch {
            // The claim is already consumed. Best-effort destruction prevents
            // a failed candidate from retaining usable signing authority.
            try? abandonAuthority(binding.sessionID)
            throw error
        }
        try abandonAuthority(binding.sessionID)
        try output.commit(envelopeData)
        return request.evidenceOutputURL
    }

    func recoverPersistedEnvelope() throws -> URL? {
        let identifier = claimIdentifier()
        guard let recoveredEnvelope =
                try recoveryStore.loadEnvelope(identifier: identifier)
        else {
            return nil
        }
        let recoveredPayload =
            try FingerprintEvidenceEnvelopeCodec.verify(
                recoveredEnvelope,
                candidateManifest: candidateManifest
            )
        try validateRecoveredPayload(recoveredPayload)
        let requestDigest = Data(
            SHA256.hash(data: candidateManifest + recoveredPayload)
        )
        if let claimed = try claimStore.claimedDigest(
            identifier: identifier
        ) {
            guard claimed == requestDigest else {
                throw FingerprintEvidenceError.bindingMismatch
            }
        } else {
            try claimStore.claim(
                identifier: identifier,
                requestDigest: requestDigest
            )
        }
        try abandonAuthority(binding.sessionID)
        try output.commit(recoveredEnvelope)
        return request.evidenceOutputURL
    }

    private func validateRecoveredPayload(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload =
                try? decoder.decode(
                    FingerprintReleaseEvidencePayload.self,
                    from: data
                ),
              try payload.encodedCanonical() == data,
              payload.schemaVersion ==
                FingerprintReleaseEvidencePayload.currentSchemaVersion,
              payload.kind ==
                FingerprintReleaseEvidencePayload.kindName,
              payload.releaseChannel == metadata.releaseChannel,
              payload.managerVersion == metadata.managerVersion,
              payload.managerBuild == metadata.managerBuild,
              payload.runtimeExecutableSHA256 ==
                metadata.runtimeExecutableSHA256,
              payload.runtimeFrameworkSHA256 ==
                metadata.runtimeFrameworkSHA256,
              payload.runtimeCodeSignatureValid,
              payload.executionMode ==
                FingerprintAuditExecutionMode.browser.rawValue,
              payload.profileSequenceValid,
              payload.identitySequenceValid
        else {
            throw FingerprintEvidenceError.bindingMismatch
        }
        switch metadata.releaseChannel {
        case .publicAlpha:
            guard payload.publicAlphaQualified else {
                throw FingerprintEvidenceError.bindingMismatch
            }
        case .production:
            guard payload.productionQualified else {
                throw FingerprintEvidenceError.bindingMismatch
            }
        }
    }

    private func validateCandidateCoherence(
        _ report: FingerprintAuditReport
    ) throws {
        guard report.managerVersion == metadata.managerVersion,
              report.managerBuild == metadata.managerBuild,
              report.runtimeExecutableSHA256 ==
                metadata.runtimeExecutableSHA256,
              report.runtimeFrameworkSHA256 ==
                metadata.runtimeFrameworkSHA256
        else {
            throw FingerprintEvidenceReleaseError
                .candidateMetadataMismatch
        }
    }

    private func claimIdentifier() -> String {
        var material = Data(
            "NeAntik fingerprint evidence claim v1\u{0}".utf8
        )
        material.append(Data(binding.authorityKeyID.utf8))
        material.append(Data(base64Encoded: binding.challenge) ?? Data())
        return Self.hex(SHA256.hash(data: material))
    }

    private static func parseCandidateMetadata(
        _ data: Data
    ) throws -> (
        metadata: FingerprintEvidenceCandidateMetadata,
        managerExecutableSHA256: String
    ) {
        guard let object =
                try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              canonical == data,
              let root = object as? [String: Any],
              Set(root.keys) == [
                  "boundary", "bundle", "bundleInventory",
                  "criticalFiles", "fingerprintEvidence", "kind",
                  "preparedAt", "postPreparationMutablePaths",
                  "releaseChannel", "schemaVersion"
              ],
              root["schemaVersion"] as? Int == 3,
              root["kind"] as? String ==
                "neantik-direct-prepared-candidate",
              let channelText = root["releaseChannel"] as? String,
              let channel =
                FingerprintEvidenceReleaseChannel(
                    rawValue: channelText
                ),
              let bundle = root["bundle"] as? [String: Any],
              Set(bundle.keys) ==
                ["name", "identifier", "version", "build"],
              bundle["name"] as? String == "NeAntik.app",
              bundle["identifier"] as? String ==
                "app.neantik.desktop",
              let version = bundle["version"] as? String,
              let build = bundle["build"] as? String,
              !version.isEmpty,
              !build.isEmpty,
              let critical =
                root["criticalFiles"] as? [String: Any],
              Set(critical.keys) == [
                  "managerInfoPlist", "managerExecutable",
                  "runtimeInfoPlist", "runtimeExecutable",
                  "runtimeFramework", "runtimeVerification",
                  "runtimeCandidateLock", "sourceContract",
                  "sourceProvenance", "buildArguments"
              ],
              critical.allSatisfy({
                  guard let entry = try? hashedEntry($0.value) else {
                      return false
                  }
                  return isExpectedCriticalPath(
                      key: $0.key,
                      path: entry.bundlePath
                  )
              }),
              let managerExecutable = try? hashedEntry(
                  critical["managerExecutable"]
              ),
              let runtimeExecutable = try? hashedEntry(
                  critical["runtimeExecutable"]
              ),
              let runtimeFramework = try? hashedEntry(
                  critical["runtimeFramework"]
              ),
              root["postPreparationMutablePaths"] as? [String] ==
                ["Contents/CodeResources"],
              root["boundary"] is String,
              root["bundleInventory"] is [Any],
              root["fingerprintEvidence"] is [String: Any]
        else {
            throw FingerprintEvidenceReleaseError.invalidManifest
        }
        return (
            FingerprintEvidenceCandidateMetadata(
                releaseChannel: channel,
                managerVersion: version,
                managerBuild: build,
                runtimeExecutableSHA256: runtimeExecutable.sha256,
                runtimeFrameworkSHA256: runtimeFramework.sha256
            ),
            managerExecutable.sha256
        )
    }

    private static func hashedEntry(
        _ value: Any?
    ) throws -> (bundlePath: String, sha256: String) {
        guard let entry = value as? [String: Any],
              Set(entry.keys) == ["bundlePath", "sha256"],
              let path = entry["bundlePath"] as? String,
              !path.isEmpty,
              let sha256 = entry["sha256"] as? String,
              isLowerSHA256(sha256)
        else {
            throw FingerprintEvidenceReleaseError.invalidManifest
        }
        return (path, sha256)
    }

    private static func isLowerSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isExpectedCriticalPath(
        key: String,
        path: String
    ) -> Bool {
        let fixed = [
            "managerInfoPlist": "Contents/Info.plist",
            "managerExecutable": "Contents/MacOS/NeAntik",
            "runtimeInfoPlist":
                "Contents/Resources/NeAntik Browser.app/Contents/Info.plist",
            "runtimeExecutable":
                "Contents/Resources/NeAntik Browser.app/Contents/MacOS/NeAntik Browser",
            "runtimeVerification":
                "Contents/Resources/NeAntikRuntimeEvidence/runtime-verification.json",
            "runtimeCandidateLock":
                "Contents/Resources/NeAntikRuntimeEvidence/fingerprint-chromium.lock.json",
            "sourceContract":
                "Contents/Resources/NeAntikRuntimeEvidence/chromium-151-source-contract.json",
            "sourceProvenance":
                "Contents/Resources/NeAntikRuntimeEvidence/source-provenance.json",
            "buildArguments":
                "Contents/Resources/NeAntikRuntimeEvidence/args.gn"
        ]
        if let expected = fixed[key] {
            return path == expected
        }
        guard key == "runtimeFramework" else { return false }
        let parts = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        let legacyFrameworkName = String(
            UnicodeScalar(78)!
        ) + String(UnicodeScalar(101)!) + String(UnicodeScalar(86)!) +
            String(UnicodeScalar(105)!) + String(UnicodeScalar(115)!) +
            String(UnicodeScalar(105)!) + String(UnicodeScalar(111)!) +
            String(UnicodeScalar(110)!) + " Browser Framework"
        guard parts.count == 9,
              Array(parts.prefix(5)) == [
                  "Contents", "Resources", "NeAntik Browser.app",
                  "Contents", "Frameworks"
              ],
              parts[6] == "Versions",
              parts[5] == "\(parts[8]).framework",
              [
                  "NeAntik Browser Framework",
                  legacyFrameworkName
              ].contains(parts[8])
        else {
            return false
        }
        let versionParts = parts[7].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return versionParts.count == 4 &&
            versionParts.allSatisfy {
                !$0.isEmpty && $0.allSatisfy(\.isNumber)
            }
    }

    static func readStableRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.path == url.standardizedFileURL.path
        else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        defer { _ = Darwin.close(descriptor) }
        var initial = stat()
        guard Darwin.fstat(descriptor, &initial) == 0,
              initial.st_mode & mode_t(S_IFMT) ==
                mode_t(S_IFREG),
              initial.st_nlink == 1,
              initial.st_uid == geteuid(),
              initial.st_size > 0,
              initial.st_size <= maximumBytes
        else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        var data = Data()
        data.reserveCapacity(Int(initial.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(
                descriptor,
                &buffer,
                min(buffer.count, maximumBytes + 1 - data.count)
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw FingerprintEvidenceReleaseError.unsafeManifest
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else {
                throw FingerprintEvidenceReleaseError.unsafeManifest
            }
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0,
              initial.st_dev == final.st_dev,
              initial.st_ino == final.st_ino,
              initial.st_nlink == final.st_nlink,
              initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec ==
                final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec ==
                final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec ==
                final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec ==
                final.st_ctimespec.tv_nsec,
              data.count == Int(final.st_size)
        else {
            throw FingerprintEvidenceReleaseError.unsafeManifest
        }
        return data
    }

    private static func hex<H: Sequence>(_ digest: H) -> String
    where H.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
