import CryptoKit
import Darwin
import Foundation

enum DirectUpdateArchiveIntegrityError: LocalizedError, Equatable {
    case notNewer, incompatibleOS, unsafeFile, limitExceeded, archiveChanged, digestMismatch, readFailed
    var errorDescription: String? {
        switch self {
        case .notNewer: "Архив не является более новой сборкой NeAntik."
        case .incompatibleOS: "Для этой сборки требуется более новая версия macOS."
        case .unsafeFile: "Выбери обычный файл архива. Ссылки и специальные файлы не поддерживаются."
        case .limitExceeded: "Размер архива превышает допустимый предел."
        case .archiveChanged: "Архив или его каталог изменился во время проверки. Повтори проверку исходного файла."
        case .digestMismatch: "Архив не совпадает с подписанным манифестом. Скачай его заново с официальной страницы выпуска."
        case .readFailed: "Не удалось прочитать архив. Проверь доступ к файлу и повтори."
        }
    }
}

/// A point-in-time integrity observation, never an installation capability.
/// A later installer must independently verify its owned immutable stage,
/// code signature, runtime provenance and notarization before publication.
struct UpdateArchiveIntegrityReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let version: String
    let build: Int
    let chromiumVersion: String
    let archiveBytes: Int64
    let sha256: String
    let checkedAt: Date
    let manifestSignatureVerified: Bool
    let archiveBytesMatchManifest: Bool
    let archiveSafetyVerified: Bool
    let developerIDVerified: Bool
    let notarizationVerified: Bool
    let installed: Bool
}

enum DirectUpdateArchiveIntegrityPoint: Sendable {
    case sourceOpened, chunkHashed(Int64), beforeFinalValidation
}

/// Explicit local-file verification. No requests, extraction, process launch,
/// profile changes or public-key adoption from the selected manifest.
enum DirectUpdateArchiveIntegrityService {
    static let maximumArchiveBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

    static func verify(
        archiveURL: URL, signedManifest: Data, configuration: UpdateChannelConfiguration,
        installedVersion: String, installedBuild: Int,
        hostOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        clock: @escaping @Sendable () -> Date = { Date() },
        byteLimit: Int64 = maximumArchiveBytes,
        fault: (@Sendable (DirectUpdateArchiveIntegrityPoint) throws -> Void)? = nil
    ) async throws -> UpdateArchiveIntegrityReceipt {
        let worker = Task.detached(priority: .utility) {
            try verifySynchronously(archiveURL: archiveURL, signedManifest: signedManifest,
                                    configuration: configuration, installedVersion: installedVersion,
                                    installedBuild: installedBuild, hostOS: hostOS, clock: clock,
                                    byteLimit: byteLimit, fault: fault)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func verifySynchronously(
        archiveURL: URL, signedManifest: Data, configuration: UpdateChannelConfiguration,
        installedVersion: String, installedBuild: Int, hostOS: OperatingSystemVersion,
        clock: @Sendable () -> Date, byteLimit: Int64 = maximumArchiveBytes,
        fault: (@Sendable (DirectUpdateArchiveIntegrityPoint) throws -> Void)? = nil
    ) throws -> UpdateArchiveIntegrityReceipt {
        try Task.checkCancellation()
        let verified = try UpdateManifestVerifier.verify(signedManifest, configuration: configuration,
                                                        installedVersion: installedVersion, installedBuild: installedBuild,
                                                        now: clock())
        guard verified.isNewerThanInstalled, installedBuild > 0,
              verified.payload.build > installedBuild else { throw DirectUpdateArchiveIntegrityError.notNewer }
        guard supports(verified.payload.minimumOS, host: hostOS) else { throw DirectUpdateArchiveIntegrityError.incompatibleOS }
        guard byteLimit > 0, byteLimit <= maximumArchiveBytes else { throw DirectUpdateArchiveIntegrityError.limitExceeded }

        // Admission precedes any file access, including security-scoped access.
        let source = try platformFileURL(archiveURL)
        let scoped = archiveURL.startAccessingSecurityScopedResource()
        defer { if scoped { archiveURL.stopAccessingSecurityScopedResource() } }
        let parentURL = source.deletingLastPathComponent(), name = source.lastPathComponent
        let parent: Int32
        do { try BackupFS.validateName(name); parent = try BackupFS.directory(parentURL) }
        catch { throw DirectUpdateArchiveIntegrityError.unsafeFile }
        defer { Darwin.close(parent) }
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw DirectUpdateArchiveIntegrityError.unsafeFile }
        defer { Darwin.close(file) }

        do {
            let parentIdentity = try BackupFS.identity(parent), initial = try BackupFS.identity(file)
            try initial.validateFile(device: nil)
            guard initial.size > 0, initial.size <= byteLimit else { throw DirectUpdateArchiveIntegrityError.limitExceeded }
            func validate() throws {
                try BackupFS.validateDirectoryPath(parentURL, parentIdentity)
                let current = try BackupFS.identity(file)
                guard current == initial, try BackupFS.entry(parent, name) == initial else {
                    throw DirectUpdateArchiveIntegrityError.archiveChanged
                }
            }
            try validate()
            try fault?(.sourceOpened)
            var offset: Int64 = 0, hash = SHA256()
            while offset < initial.size {
                try Task.checkCancellation()
                try validate()
                let count = Int(min(65_536, initial.size - offset))
                let bytes = try BackupFS.read(file, at: offset, count: count)
                guard bytes.count == count else { throw DirectUpdateArchiveIntegrityError.archiveChanged }
                hash.update(data: bytes); offset += Int64(count)
                try fault?(.chunkHashed(offset))
            }
            try fault?(.beforeFinalValidation)
            try Task.checkCancellation()
            try validate()
            let actualHash = BackupFS.hex(hash.finalize())
            guard actualHash == verified.payload.sha256 else { throw DirectUpdateArchiveIntegrityError.digestMismatch }
            let checkedAt = clock()
            // Do not issue a fresh receipt for a manifest that expired during
            // hashing, even if its initial signature was correct.
            _ = try UpdateManifestVerifier.verify(signedManifest, configuration: configuration,
                                                   installedVersion: installedVersion, installedBuild: installedBuild,
                                                   now: checkedAt)
            try Task.checkCancellation()
            try validate()
            return .init(schemaVersion: 1, version: verified.payload.version, build: verified.payload.build,
                         chromiumVersion: verified.payload.chromiumVersion, archiveBytes: initial.size,
                         sha256: actualHash, checkedAt: checkedAt,
                         manifestSignatureVerified: true, archiveBytesMatchManifest: true,
                         archiveSafetyVerified: false, developerIDVerified: false,
                         notarizationVerified: false, installed: false)
        } catch is CancellationError { throw CancellationError() }
        catch let error as DirectUpdateArchiveIntegrityError { throw error }
        catch let error as UpdateManifestError { throw error }
        catch BrowserDataBackupStorageError.changed { throw DirectUpdateArchiveIntegrityError.archiveChanged }
        catch BrowserDataBackupStorageError.unsafeEntry { throw DirectUpdateArchiveIntegrityError.unsafeFile }
        catch { throw DirectUpdateArchiveIntegrityError.readFailed }
    }

    private static func supports(_ minimum: String, host: OperatingSystemVersion) -> Bool {
        // The signature verifier already enforces canonical OS syntax.
        let minimumParts = minimum.split(separator: ".").compactMap { Int($0) }
        guard (1...3).contains(minimumParts.count), host.majorVersion >= 0,
              host.minorVersion >= 0, host.patchVersion >= 0 else { return false }
        let required = minimumParts + Array(repeating: 0, count: 3 - minimumParts.count)
        let actual = [host.majorVersion, host.minorVersion, host.patchVersion]
        for (value, baseline) in zip(actual, required) where value != baseline { return value > baseline }
        return true
    }

    private static func platformFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost" else { throw DirectUpdateArchiveIntegrityError.unsafeFile }
        // Darwin's fixed aliases only. Arbitrary symlink ancestry stays refused.
        for alias in ["var", "tmp"] where url.path.hasPrefix("/" + alias + "/") {
            let target: String
            do { target = try FileManager.default.destinationOfSymbolicLink(atPath: "/" + alias) }
            catch { throw DirectUpdateArchiveIntegrityError.unsafeFile }
            guard target == "private/" + alias || target == "/private/" + alias else { throw DirectUpdateArchiveIntegrityError.unsafeFile }
            return URL(fileURLWithPath: "/private" + url.path)
        }
        return url
    }
}
