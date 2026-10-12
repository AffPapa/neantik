import CryptoKit
import Darwin
import DirectZipCodec
import Foundation

enum CRXPreparationError: LocalizedError, Equatable {
    case incompatible, keyMismatch, changed, alreadyPrepared, storage, retained
    var errorDescription: String? {
        switch self {
        case .incompatible: "Подготовка поддерживает Manifest V3 и глубину папок до 26 уровней. Пакет не изменён."
        case .keyMismatch: "Ключ в manifest не соответствует проверенной подписи CRX. Нужен исходный пакет от разработчика."
        case .changed: "Данные или профиль изменились во время подготовки. Выбери пакет заново."
        case .alreadyPrepared: "Этот пакет уже подготовлен. Существующие файлы не перезаписаны: проверь расширение в Chromium."
        case .storage: "Не удалось подготовить пакет. Проверь свободное место и доступ к данным профиля."
        case .retained: "Подготовка не завершена. Каталог сохранён, потому что его безопасное удаление не подтверждено. Не загружай его в Chromium."
        }
    }
}

struct PreparedCRXPackage: Sendable {
    let payload: URL
    /// Retained signed bytes for Chromium's native, user-confirmed CRX install.
    /// Revealing this file is not installation or an extension trust verdict.
    let originalCRX: URL
    let extensionID: String
    let manifestKeyAdded: Bool
}

/// Original, signature-verified bytes retained for a native install prompt.
/// This is neither an unpacked extension nor proof of installation.
struct RetainedCRXPackage: Sendable {
    let originalCRX: URL
    let inspection: CRXPackageInspection

    /// Freshly checks the file before revealing it; Finder and Chromium must
    /// still perform their own admission when the user subsequently drags it.
    func validateForReveal() throws {
        guard try CRXPackageInspection.capture(originalCRX).inspection == inspection else {
            throw CRXPreparationError.changed
        }
    }
}

/// Retains signed CRX bytes or prepares a native Load unpacked folder. Never writes
/// Chromium preferences, grants permissions, launches code or marks installed.
/// Published folders remain: Chromium can modify metadata after native loading.
enum CRXPackagePreparation {
    enum Point: Equatable, Sendable { case created, writing, decoded, extracted, sealed, beforePublish, published }
    struct Receipt: Codable {
        let schema: Int
        let extensionID: String
        let packageSHA256: String
        let developerSPKISHA256: String
        let originalManifestSHA256: String
        let preparedManifestSHA256: String
        let manifestKeyAdded: Bool
        let files: [String: String]
        let status: String
    }
    struct PackedReceipt: Codable {
        let schema: Int
        let extensionID: String
        let packageSHA256: String
        let developerSPKISHA256: String
        let status: String
    }
    private struct Publication { let directory: URL; let manifestKeyAdded: Bool }

    /// The caller must hold stopped-profile maintenance authority for the
    /// entire operation. Tests supply only synthetic authority/fault controls.
    static func prepare(_ package: CRXPackageInspection.Captured, expected: CRXPackageInspection,
                        browserData: URL, validate: @Sendable () throws -> Void,
                        fault: @Sendable (Point, URL) throws -> Void = { _, _ in }) throws -> PreparedCRXPackage {
        let result = try publish(package, expected: expected, browserData: browserData, unpack: true, validate: validate, fault: fault)
        return PreparedCRXPackage(payload: result.directory.appendingPathComponent("payload"),
                                  originalCRX: result.directory.appendingPathComponent("original.crx"),
                                  extensionID: expected.extensionID, manifestKeyAdded: result.manifestKeyAdded)
    }

    /// Keeps the exact signed CRX, without rewriting or extracting its manifest.
    /// The caller holds the same stopped-profile authority as unpacked preparation.
    static func retainPacked(_ package: CRXPackageInspection.Captured, expected: CRXPackageInspection,
                             browserData: URL, validate: @Sendable () throws -> Void,
                             fault: @Sendable (Point, URL) throws -> Void = { _, _ in }) throws -> RetainedCRXPackage {
        let result = try publish(package, expected: expected, browserData: browserData, unpack: false, validate: validate, fault: fault)
        return RetainedCRXPackage(originalCRX: result.directory.appendingPathComponent("original.crx"), inspection: expected)
    }

    private static func publish(_ package: CRXPackageInspection.Captured, expected: CRXPackageInspection,
                                browserData: URL, unpack: Bool, validate: @Sendable () throws -> Void,
                                fault: @Sendable (Point, URL) throws -> Void) throws -> Publication {
        guard package.inspection == expected else { throw CRXPreparationError.changed }
        if unpack {
            guard expected.manifestVersion == 3,
                  package.archive.inventory.allSatisfy({ $0.path.split(separator: "/").count <= 26 }) else {
                throw CRXPreparationError.incompatible
            }
        }
        // A generated manifest is explicitly derived, never labelled signed.
        guard var manifest = try JSONSerialization.jsonObject(with: package.archive.manifest) as? [String: Any] else { throw CRXPackageInspectionError.manifest }
        let spki = package.proof.developerSPKI
        let added = unpack && manifest["key"] == nil
        if unpack, let key = manifest["key"] {
            guard let encoded = key as? String, Data(base64Encoded: encoded) == spki else { throw CRXPreparationError.keyMismatch }
        } else if added { manifest["key"] = spki.base64EncodedString() }
        let generated = added ? try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) : package.archive.manifest
        try Task.checkCancellation(); try validate()
        let canonical = try DirectUpdateArchiveIntegrityService.platformFileURL(browserData)
        let root = try BackupFS.directory(canonical); defer { close(root) }
        let rootIdentity = try BackupFS.identity(root)
        guard rootIdentity.mode & 0o077 == 0 else { throw CRXPreparationError.changed }
        let namespaceName = unpack ? "NeAntikPreparedExtensions" : "NeAntikRetainedCRX"
        let namespace = try childDirectory(root, namespaceName); defer { close(namespace) }
        let nsIdentity = try BackupFS.identity(namespace)
        let parent = try childDirectory(namespace, expected.extensionID); defer { close(parent) }
        let parentIdentity = try BackupFS.identity(parent)
        func validateParents() throws {
            try validate(); try BackupFS.validateDirectoryPath(canonical, rootIdentity)
            guard try BackupFS.identity(root).mode == rootIdentity.mode,
                  try BackupFS.entry(root, namespaceName)?.sameObject(nsIdentity) == true,
                  try BackupFS.identity(namespace).mode == nsIdentity.mode,
                  try BackupFS.entry(namespace, expected.extensionID)?.sameObject(parentIdentity) == true,
                  try BackupFS.identity(parent).mode == parentIdentity.mode else {
                throw CRXPreparationError.changed
            }
        }
        try validateParents()
        guard try BackupFS.entry(parent, expected.packageSHA256) == nil else { throw CRXPreparationError.alreadyPrepared }
        let stageName = ".stage-" + UUID().uuidString
        guard mkdirat(parent, stageName, 0o700) == 0 else { throw CRXPreparationError.storage }
        let stage = openat(parent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw CRXPreparationError.retained }
        defer { close(stage) }
        let stageIdentity = try BackupFS.identity(stage)
        let stageURL = canonical.appendingPathComponent(namespaceName).appendingPathComponent(expected.extensionID).appendingPathComponent(stageName)
        var tree = Tree(root: stage, identity: stageIdentity)
        var published = false
        do {
            try fault(.created, stageURL)
            if unpack { try tree.makeDirectory("payload") }
            try Task.checkCancellation(); try validateParents()
            if !unpack { try fault(.writing, stageURL) }
            let original = try tree.createFile("original.crx", bytes: package.bytes)
            defer { close(original) }
            guard try BackupFS.hash(original, size: Int64(package.bytes.count)) == expected.packageSHA256 else { throw CRXPreparationError.changed }
            for entry in unpack ? package.archive.inventory : [] {
                try Task.checkCancellation(); try validateParents()
                try fault(.writing, stageURL)
                let destination = "payload/" + entry.path
                if entry.directory { try tree.makeDirectory(destination); continue }
                let fd = try tree.createFile(destination); defer { close(fd) }
                do {
                    let status = neantik_zip_decode_fd(original, UInt64(package.proof.archiveOffset + entry.offset),
                        UInt64(entry.compressed), fd, UInt64(entry.expanded), entry.method, entry.crc,
                        { _ in Task.isCancelled ? 1 : 0 }, nil)
                    if status == NEANTIK_ZIP_CANCELLED { throw CancellationError() }
                    guard status == NEANTIK_ZIP_OK else { throw CRXPreparationError.storage }
                    try fault(.decoded, stageURL)
                    if entry.path == "manifest.json" && added {
                        guard ftruncate(fd, 0) == 0 else { throw CRXPreparationError.storage }
                        try BackupFS.write(fd, generated, at: 0)
                    }
                    try tree.sealFile(destination, fd: fd)
                } catch {
                    try tree.capturePartialFile(destination, fd: fd)
                    throw error
                }
            }
            try fault(.extracted, stageURL)
            let receiptData: Data
            if unpack {
                let receipt = Receipt(schema: 1, extensionID: expected.extensionID, packageSHA256: expected.packageSHA256,
                developerSPKISHA256: digest(spki), originalManifestSHA256: digest(package.archive.manifest),
                preparedManifestSHA256: digest(generated), manifestKeyAdded: added,
                files: tree.hashes.filter { $0.key.hasPrefix("payload/") }, status: "prepared-not-installed")
                receiptData = try JSONEncoder().encode(receipt)
            } else {
                receiptData = try JSONEncoder().encode(PackedReceipt(schema: 1, extensionID: expected.extensionID,
                    packageSHA256: expected.packageSHA256, developerSPKISHA256: digest(spki), status: "retained-not-installed"))
            }
            let receiptFD = try tree.createFile("receipt.json", bytes: receiptData); close(receiptFD)
            try tree.sealDirectories()
            try fault(.sealed, stageURL)
            try tree.verify()
            try fault(.beforePublish, stageURL)
            try Task.checkCancellation(); try validateParents(); try tree.verify()
            guard try BackupFS.entry(parent, stageName)?.sameObject(stageIdentity) == true else { throw CRXPreparationError.changed }
            guard renameatx_np(parent, stageName, parent, expected.packageSHA256, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw CRXPreparationError.alreadyPrepared }; throw CRXPreparationError.storage
            }
            // Record the ownership transition before any throwable operation.
            published = true
            try fault(.published, stageURL)
            guard fsync(parent) == 0 else { throw CRXPreparationError.retained }
            try validateParents()
            guard try BackupFS.entry(parent, expected.packageSHA256)?.sameObject(stageIdentity) == true else { throw CRXPreparationError.retained }
            let publishedDirectory = stageURL.deletingLastPathComponent().appendingPathComponent(expected.packageSHA256)
            return Publication(directory: publishedDirectory, manifestKeyAdded: added)
        } catch {
            // Never delete a visible published folder: native loading can have
            // started. Unknown/replaced staging objects are retained as well.
            if published { throw CRXPreparationError.retained }
            do {
                try validateParents()
                guard try BackupFS.entry(parent, stageName)?.sameObject(stageIdentity) == true else { throw CRXPreparationError.changed }
                try tree.verify()
                let retired = ".retired-" + UUID().uuidString
                guard renameatx_np(parent, stageName, parent, retired, UInt32(RENAME_EXCL)) == 0,
                      try BackupFS.entry(parent, retired)?.sameObject(stageIdentity) == true else { throw CRXPreparationError.retained }
                try tree.removeOwned()
                try validateParents()
                guard try BackupFS.entry(parent, retired)?.sameObject(stageIdentity) == true,
                      unlinkat(parent, retired, AT_REMOVEDIR) == 0, fsync(parent) == 0 else { throw CRXPreparationError.retained }
            } catch { throw CRXPreparationError.retained }
            throw error
        }
    }

    private static func digest(_ data: Data) -> String { BackupFS.hex(SHA256.hash(data: data)) }
    private static func childDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
        try BackupFS.validateName(name)
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw CRXPreparationError.storage }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CRXPreparationError.changed }
        do {
            let identity = try BackupFS.identity(fd)
            guard identity.directory, identity.uid == getuid(), identity.mode & 0o077 == 0,
                  try BackupFS.entry(parent, name)?.sameObject(identity) == true else { throw CRXPreparationError.changed }
            guard fsync(parent) == 0 else { throw CRXPreparationError.storage }
            return fd
        } catch { close(fd); throw error }
    }

    /// Descriptor-relative ownership journal. Failed writers remain owned but
    /// unsealed; cleanup can remove them only if exact inode/size/mtime match.
    private struct Tree {
        let root: Int32
        let identity: BackupIdentity
        var objects: [String: BackupIdentity] = [:]
        var hashes: [String: String] = [:]
        private func checkedDirectory(_ path: String) throws -> Int32 {
            var fd = dup(root)
            guard fd >= 0 else { throw CRXPreparationError.storage }
            do {
                guard try BackupFS.identity(fd).sameObject(identity), try BackupFS.identity(fd).mode == identity.mode else { throw CRXPreparationError.changed }
                var parts: [String] = []
                for part in path.split(separator: "/").map(String.init) {
                    parts.append(part)
                    guard let expected = objects[parts.joined(separator: "/")], expected.directory,
                          let linked = try BackupFS.entry(fd, part), linked.sameObject(expected), linked.mode == expected.mode else { throw CRXPreparationError.changed }
                    let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw CRXPreparationError.changed }
                    close(fd); fd = next
                    let current = try BackupFS.identity(fd)
                    guard current.sameObject(expected), current.mode == expected.mode else { throw CRXPreparationError.changed }
                }
                return fd
            } catch { close(fd); throw error }
        }
        private func checkedParent(_ path: String) throws -> Int32 {
            try checkedDirectory(path.split(separator: "/").dropLast().joined(separator: "/"))
        }
        mutating func makeDirectory(_ path: String) throws {
            let parts = path.split(separator: "/").map(String.init)
            for index in 1...parts.count {
                let prefix = parts.prefix(index).joined(separator: "/")
                if objects[prefix] != nil { continue }
                let parent = try checkedParent(prefix); defer { close(parent) }
                guard mkdirat(parent, parts[index - 1], 0o700) == 0 else { throw CRXPreparationError.changed }
                let fd = openat(parent, parts[index - 1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw CRXPreparationError.changed }; defer { close(fd) }
                let object = try BackupFS.identity(fd)
                guard object.directory, object.uid == identity.uid, object.device == identity.device, object.mode & 0o777 == 0o700,
                      try BackupFS.entry(parent, parts[index - 1])?.sameObject(object) == true else { throw CRXPreparationError.changed }
                objects[prefix] = object
            }
        }
        mutating func createFile(_ path: String, bytes: Data? = nil) throws -> Int32 {
            let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
            if !parentPath.isEmpty { try makeDirectory(parentPath) }
            let parent = try checkedParent(path); defer { close(parent) }
            let fd = openat(parent, (path as NSString).lastPathComponent, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CRXPreparationError.storage }
            objects[path] = try BackupFS.identity(fd)
            do {
                if let bytes { try BackupFS.write(fd, bytes, at: 0); try sealFile(path, fd: fd) }
                return fd
            } catch {
                // Capture partial writes only on the still-owned inode.
                if let current = try? BackupFS.identity(fd), objects[path]?.sameObject(current) == true { objects[path] = current }
                close(fd); throw error
            }
        }
        mutating func sealFile(_ path: String, fd: Int32) throws {
            let current = try BackupFS.identity(fd)
            guard objects[path]?.sameObject(current) == true else { throw CRXPreparationError.changed }
            try current.validateFile(device: identity.device)
            objects[path] = current // partial data remain owned if fsync fails
            guard fsync(fd) == 0 else { throw CRXPreparationError.storage }
            hashes[path] = try BackupFS.hash(fd, size: current.size)
        }
        mutating func capturePartialFile(_ path: String, fd: Int32) throws {
            let current = try BackupFS.identity(fd)
            guard objects[path]?.sameObject(current) == true else { throw CRXPreparationError.changed }
            try current.validateFile(device: identity.device)
            let hash = try BackupFS.hash(fd, size: current.size, checksCancellation: false)
            guard try BackupFS.identity(fd) == current else { throw CRXPreparationError.changed }
            objects[path] = current; hashes[path] = hash
        }
        func sealDirectories() throws {
            for (path, object) in objects where object.directory {
                let fd = try checkedDirectory(path); defer { close(fd) }
                guard try BackupFS.identity(fd).sameObject(object), fsync(fd) == 0 else { throw CRXPreparationError.changed }
            }
            guard fsync(root) == 0 else { throw CRXPreparationError.storage }
        }
        func verify() throws {
            try verifyMetadata()
            for (path, hash) in hashes {
                let object = objects[path]!, parent = try checkedParent(path); defer { close(parent) }
                let fd = openat(parent, (path as NSString).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw CRXPreparationError.changed }; defer { close(fd) }
                guard try BackupFS.identity(fd) == object, try BackupFS.hash(fd, size: object.size, checksCancellation: false) == hash,
                      try BackupFS.identity(fd) == object else { throw CRXPreparationError.changed }
            }
            // Detect late changes to earlier leaves while later files were hashed.
            try verifyMetadata()
        }
        private func verifyMetadata() throws {
            guard try BackupFS.identity(root).sameObject(identity) else { throw CRXPreparationError.changed }
            for path in [""] + objects.filter { $0.value.directory }.map(\.key) {
                let fd = try checkedDirectory(path); defer { close(fd) }
                let expected = path.isEmpty ? identity : objects[path]!
                guard try BackupFS.identity(fd).sameObject(expected) else { throw CRXPreparationError.changed }
                let names = objects.keys.filter { ($0 as NSString).deletingLastPathComponent == path }.map { ($0 as NSString).lastPathComponent }.sorted()
                guard try BackupFS.names(fd) == names else { throw CRXPreparationError.changed }
            }
            for (path, object) in objects {
                let parent = try checkedParent(path); defer { close(parent) }
                guard let current = try BackupFS.entry(parent, (path as NSString).lastPathComponent),
                      object.directory ? current.sameObject(object) && current.mode == object.mode : current == object else { throw CRXPreparationError.changed }
            }
        }

        func removeOwned() throws {
            try verify()
            for path in objects.keys.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
                let object = objects[path]!, parent = try checkedParent(path); defer { close(parent) }
                guard let current = try BackupFS.entry(parent, (path as NSString).lastPathComponent),
                      object.directory ? current.sameObject(object) : current == object else { throw CRXPreparationError.changed }
                guard unlinkat(parent, (path as NSString).lastPathComponent, object.directory ? AT_REMOVEDIR : 0) == 0 else { throw CRXPreparationError.retained }
            }
        }
    }
}
