import CryptoKit
import Darwin
import Foundation
import Security

struct FingerprintEvidenceReleaseRequest: Equatable, Sendable {
    let candidateManifestURL: URL
    let evidenceOutputURL: URL
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
}

struct KeychainFingerprintEvidenceChallengeClaimStore:
    FingerprintEvidenceChallengeClaiming, @unchecked Sendable
{
    private static let service =
        "app.neantik.fingerprint-evidence.consumed-challenge.v1"
    private let addItem: ([String: Any]) -> OSStatus

    init(
        addItem: @escaping ([String: Any]) -> OSStatus = {
            SecItemAdd($0 as CFDictionary, nil)
        }
    ) {
        self.addItem = addItem
    }

    func claim(identifier: String, requestDigest: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
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
    private let signer: any FingerprintEvidenceSigning
    private let abandonAuthority: (UUID) throws -> Void
    private let claimStore: any FingerprintEvidenceChallengeClaiming
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
    ) throws -> FingerprintEvidenceReleaseContext {
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
        let signer = try authority.existingSigner(
            sessionID: binding.sessionID,
            expectedPublicKeyX963:
                validated.publicKey.x963Representation
        )
        let output: any FingerprintEvidenceEnrollmentOutput
        do {
            output =
                try ReservedFingerprintEvidenceEnrollmentOutput(
                    url: request.evidenceOutputURL
                )
        } catch {
            throw FingerprintEvidenceReleaseError.outputUnavailable
        }
        return FingerprintEvidenceReleaseContext(
            request: request,
            candidateManifest: manifest,
            metadata: parsed.metadata,
            binding: binding,
            signer: signer,
            abandonAuthority: {
                try authority.abandon(sessionID: $0)
            },
            claimStore: claimStore,
            output: output
        )
    }

    init(
        request: FingerprintEvidenceReleaseRequest,
        candidateManifest: Data,
        metadata: FingerprintEvidenceCandidateMetadata,
        binding: FingerprintEvidenceManifestBinding,
        signer: any FingerprintEvidenceSigning,
        abandonAuthority: @escaping (UUID) throws -> Void,
        claimStore: any FingerprintEvidenceChallengeClaiming,
        output: any FingerprintEvidenceEnrollmentOutput
    ) {
        self.request = request
        self.candidateManifest = candidateManifest
        self.metadata = metadata
        self.binding = binding
        self.signer = signer
        self.abandonAuthority = abandonAuthority
        self.claimStore = claimStore
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
        try validateCandidateCoherence(report)
        let payload = try FingerprintReleaseEvidencePayload(
            report: report,
            releaseChannel: metadata.releaseChannel
        ).encodedCanonical()
        let requestDigest = SHA256.hash(
            data: candidateManifest + payload
        )
        try claimStore.claim(
            identifier: claimIdentifier(),
            requestDigest: Data(requestDigest)
        )
        let envelope = try FingerprintEvidenceEnvelopeCodec.make(
            payload: payload,
            candidateManifest: candidateManifest,
            signer: signer
        )
        let envelopeData =
            try FingerprintEvidenceEnvelopeCodec.encode(envelope)
        guard try FingerprintEvidenceEnvelopeCodec.verify(
            envelopeData,
            candidateManifest: candidateManifest
        ) == payload else {
            throw FingerprintEvidenceError.invalidSignature
        }

        // A challenge is intentionally one-shot. Destroy the signing key before
        // publication; any later failure burns the candidate instead of
        // allowing a second, different report to be signed.
        try abandonAuthority(binding.sessionID)
        try output.commit(envelopeData)
        return request.evidenceOutputURL
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
                "Contents/Resources/NeAntikRuntimeEvidence/chromium-150-source-contract.json",
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
        guard parts.count == 9,
              Array(parts.prefix(5)) == [
                  "Contents", "Resources", "NeAntik Browser.app",
                  "Contents", "Frameworks"
              ],
              parts[6] == "Versions",
              parts[5] == "\(parts[8]).framework",
              [
                  "NeAntik Browser Framework",
                  "NeVision Browser Framework"
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

    private static func readStableRegularFile(
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
