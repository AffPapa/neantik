import CoreFoundation
import Darwin
import DirectZipCodec
import Foundation

enum CRXPackageInspectionError: LocalizedError, Equatable {
    case unsafeFile, changed, archive, limit, manifest, signature
    var errorDescription: String? {
        switch self {
        case .unsafeFile: "Выбери обычный файл CRX. Ссылки, папки и специальные файлы не читаются."
        case .changed: "Файл изменился во время проверки. Выбери его заново."
        case .archive: "Архив внутри CRX повреждён или имеет неподдерживаемую структуру. Нужен исходный пакет от разработчика."
        case .limit: "Пакет превышает лимит проверки: 64 МБ CRX, 256 МБ содержимого или 2048 записей."
        case .manifest: "Manifest расширения отсутствует, повреждён или неоднозначен. Нужен исходный пакет от разработчика."
        case .signature: "Подпись разработчика CRX3 не прошла проверку. Не устанавливай этот пакет. Старые CRX2 не поддерживаются."
        }
    }
}

struct CRXPackageInspection: Equatable, Sendable {
    let extensionID: String
    let packageSHA256: String
    let name: String
    let version: String
    let manifestVersion: Int
    let permissions: [String]
    let optionalPermissions: [String]
    let entryCount: Int
    let expandedBytes: Int
    let localizedName: Bool

    /// Off-main, no extraction, network, execution or profile writes. A valid
    /// developer signature authenticates bytes, not the author's trustworthiness.
    static func inspect(_ package: Data) throws -> Self {
        try capture(package).inspection
    }

    struct Captured: Sendable {
        let bytes: Data
        let inspection: CRXPackageInspection
        let proof: CRX3SignatureVerifier.Verification
        let archive: CRXArchiveInspection.Result
    }

    static func capture(_ package: Data) throws -> Captured {
        let proof: CRX3SignatureVerifier.Verification
        do { proof = try CRX3SignatureVerifier.verify(package) }
        catch is CancellationError { throw CancellationError() }
        catch CRX3SignatureVerifier.Failure.limitExceeded { throw CRXPackageInspectionError.limit }
        catch { throw CRXPackageInspectionError.signature }
        let archive = Data(package.dropFirst(proof.archiveOffset))
        let result = try CRXArchiveInspection.read(archive)
        do {
            try ImportJSONShape.validate(result.manifest)
            guard let object = try JSONSerialization.jsonObject(with: result.manifest) as? [String: Any],
                  let name = text(object["name"], limit: 512),
                  let version = text(object["version"], limit: 128),
                  let number = object["manifest_version"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let manifestVersion = Int(number.stringValue), [2, 3].contains(manifestVersion) else {
                throw CRXPackageInspectionError.manifest
            }
            let inspection = Self(extensionID: proof.extensionID, packageSHA256: proof.packageSHA256,
                name: name, version: version, manifestVersion: manifestVersion,
                permissions: try strings(object["permissions"]) + strings(object["host_permissions"]),
                optionalPermissions: try strings(object["optional_permissions"]) + strings(object["optional_host_permissions"]),
                entryCount: result.entries, expandedBytes: result.expanded, localizedName: name.hasPrefix("__MSG_"))
            return Captured(bytes: Data(package), inspection: inspection, proof: proof, archive: result)
        } catch is CancellationError { throw CancellationError() }
        catch { throw CRXPackageInspectionError.manifest }
    }

    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= limit,
              PersistedInlineText.isSafe(text) else { return nil }; return text
    }
    private static func strings(_ value: Any?) throws -> [String] {
        guard let value else { return [] }
        guard let values = value as? [String], values.count <= 256 else { throw CRXPackageInspectionError.manifest }
        return try values.map {
            guard let text = text($0, limit: 2048) else { throw CRXPackageInspectionError.manifest }; return text
        }
    }

    /// Captures one selected file through a no-follow descriptor. Replacement,
    /// mutation and hard links invalidate the result before it reaches the UI.
    static func read(_ url: URL, afterRead: () throws -> Void = {}) throws -> Self {
        try capture(url, afterRead: afterRead).inspection
    }

    static func capture(_ url: URL, afterRead: () throws -> Void = {}) throws -> Captured {
        guard url.isFileURL else { throw CRXPackageInspectionError.unsafeFile }
        let canonical = try DirectUpdateArchiveIntegrityService.platformFileURL(url)
        let parentURL = canonical.deletingLastPathComponent()
        try BackupFS.validateName(canonical.lastPathComponent)
        let parent = try BackupFS.directory(parentURL); defer { Darwin.close(parent) }
        let parentIdentity = try BackupFS.identity(parent)
        let fd = openat(parent, canonical.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CRXPackageInspectionError.unsafeFile }; defer { Darwin.close(fd) }
        let before = try BackupFS.identity(fd)
        guard before.mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.links == 1, before.size > 0 else {
            throw CRXPackageInspectionError.unsafeFile
        }
        guard before.size <= CRX3SignatureVerifier.maximumPackageBytes else { throw CRXPackageInspectionError.limit }
        var data = Data(), offset: Int64 = 0
        while offset < before.size {
            try Task.checkCancellation()
            let chunk = try BackupFS.read(fd, at: offset, count: Int(min(65_536, before.size - offset)))
            guard !chunk.isEmpty else { throw CRXPackageInspectionError.changed }
            data.append(chunk); offset += Int64(chunk.count)
        }
        try afterRead()
        let result = try capture(data)
        try Task.checkCancellation()
        try BackupFS.validateDirectoryPath(parentURL, parentIdentity)
        guard try BackupFS.identity(fd) == before,
              try BackupFS.entry(parent, canonical.lastPathComponent) == before else { throw CRXPackageInspectionError.changed }
        return result
    }
}

/// Rootless ZIP32 validation for CRX, separate from the app updater contract.
/// Every record is checked and decompressed with exact size/CRC, but only the
/// bounded manifest is retained. No paths are extracted or opened from ZIP.
enum CRXArchiveInspection {
    struct Entry: Sendable {
        let path: String
        let directory: Bool
        let offset: Int
        let compressed: Int
        let expanded: Int
        let method: UInt16
        let crc: UInt32
    }
    struct Result: Sendable {
        let manifest: Data; let entries: Int; let expanded: Int
        let inventory: [Entry]
    }
    static func read(_ input: Data) throws -> Result {
        let data = Data(input) // normalize indices before offset arithmetic
        func bytes(_ offset: Int, _ count: Int) throws -> Data {
            try Task.checkCancellation()
            guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
                throw CRXPackageInspectionError.archive
            }
            return Data(data[offset..<(offset + count)])
        }
        guard data.count >= 22, data.count <= CRX3SignatureVerifier.maximumPackageBytes else { throw CRXPackageInspectionError.archive }
        let tail = max(0, data.count - 65_557)
        let ends = (tail...(data.count - 22)).filter {
            data.crx32($0) == 0x06054b50 && $0 + 22 + Int(data.crx16($0 + 20)) == data.count
        }
        guard ends.count == 1, let end = ends.first else { throw CRXPackageInspectionError.archive }
        let count = Int(data.crx16(end + 10)), central = Int(data.crx32(end + 16)), centralSize = Int(data.crx32(end + 12))
        guard count <= 2048 else { throw CRXPackageInspectionError.limit }
        guard data.crx16(end + 4) == 0, data.crx16(end + 6) == 0,
              Int(data.crx16(end + 8)) == count, count > 0, central > 0, centralSize > 0,
              central <= end, centralSize == end - central else { throw CRXPackageInspectionError.archive }
        var inventory: [Entry] = []
        var cursor = central, expandedTotal = 0, manifest: Data?
        var names: [String: Bool] = [:], canonicalNames: [String: String] = [:], ranges: [(Int, Int)] = []
        for _ in 0..<count {
            let header = try bytes(cursor, 46)
            guard header.crx32(0) == 0x02014b50 else { throw CRXPackageInspectionError.archive }
            let needed = header.crx16(6), flags = header.crx16(8), method = header.crx16(10), crc = header.crx32(16)
            let compressed = Int(header.crx32(20)), expanded = Int(header.crx32(24))
            let nameSize = Int(header.crx16(28)), extraSize = Int(header.crx16(30)), commentSize = Int(header.crx16(32))
            let attributes = header.crx32(38), localOffset = Int(header.crx32(42)), system = header[5]
            guard needed <= 20, [0, 3].contains(system), flags & ~UInt16(0x0808) == 0,
                  [0, 8].contains(method), header.crx16(34) == 0, nameSize > 0, nameSize <= 1024,
                  localOffset < central else { throw CRXPackageInspectionError.archive }
            guard expanded <= 256 * 1024 * 1024 - expandedTotal else { throw CRXPackageInspectionError.limit }
            expandedTotal += expanded
            let variable = try bytes(cursor + 46, nameSize + extraSize + commentSize), rawName = Data(variable.prefix(nameSize))
            try extra(Data(variable[nameSize..<(nameSize + extraSize)]))
            guard let name = String(data: rawName, encoding: .utf8) else { throw CRXPackageInspectionError.archive }
            let directory = name.hasSuffix("/"), path = directory ? String(name.dropLast()) : name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !path.isEmpty, parts.count <= 32, !path.hasPrefix("/"), !path.contains("\\"),
                  path == path.precomposedStringWithCanonicalMapping else { throw CRXPackageInspectionError.archive }
            for part in parts {
                guard !part.isEmpty, part.utf8.count <= 255, part != ".", part != "..", !part.contains(":"),
                      PersistedInlineText.isSafe(part) else { throw CRXPackageInspectionError.archive }
            }
            let mode = attributes >> 16, type = mode & 0o170000
            guard (system == 0 || (mode & 0o7000 == 0 && (type == 0 || type == (directory ? 0o040000 : 0o100000)))),
                  attributes & 0x400 == 0,
                  attributes & 0x10 == 0 || directory, names[path] == nil else { throw CRXPackageInspectionError.archive }
            names[path] = directory
            for n in 1...parts.count {
                let prefix = parts.prefix(n).joined(separator: "/")
                let key = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard canonicalNames[key] == nil || canonicalNames[key] == prefix else { throw CRXPackageInspectionError.archive }
                canonicalNames[key] = prefix
            }
            let local = try bytes(localOffset, 30)
            guard local.crx32(0) == 0x04034b50, local.crx16(4) == needed, local.crx16(6) == flags,
                  local.crx16(8) == method, Int(local.crx16(26)) == nameSize else { throw CRXPackageInspectionError.archive }
            let localExtra = Int(local.crx16(28)), localVariable = try bytes(localOffset + 30, nameSize + localExtra)
            guard Data(localVariable.prefix(nameSize)) == rawName else { throw CRXPackageInspectionError.archive }
            try extra(Data(localVariable.dropFirst(nameSize)))
            let offset = localOffset + 30 + nameSize + localExtra
            var recordEnd = offset + compressed
            guard recordEnd <= central else { throw CRXPackageInspectionError.archive }
            if flags & 8 == 0 {
                guard local.crx32(14) == crc, Int(local.crx32(18)) == compressed, Int(local.crx32(22)) == expanded else {
                    throw CRXPackageInspectionError.archive
                }
            } else {
                let prefix = try bytes(recordEnd, 4), signed = prefix.crx32(0) == 0x08074b50
                let descriptor = try bytes(recordEnd, signed ? 16 : 12), base = signed ? 4 : 0
                guard [0, crc].contains(local.crx32(14)), [0, compressed].contains(Int(local.crx32(18))),
                      [0, expanded].contains(Int(local.crx32(22))), descriptor.crx32(base) == crc,
                      Int(descriptor.crx32(base + 4)) == compressed, Int(descriptor.crx32(base + 8)) == expanded else {
                    throw CRXPackageInspectionError.archive
                }
                recordEnd += signed ? 16 : 12
            }
            guard recordEnd <= central, !directory || (expanded == 0 && crc == 0) else { throw CRXPackageInspectionError.archive }
            let isManifest = path == "manifest.json" && !directory
            guard !isManifest || expanded <= 1024 * 1024 else { throw CRXPackageInspectionError.limit }
            var output = Data(count: isManifest ? expanded : 0)
            let compressedData = try bytes(offset, compressed)
            let status = compressedData.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { buffer in
                    neantik_zip_verify_memory(input.baseAddress, input.count, UInt64(expanded), method, crc,
                        isManifest ? buffer.baseAddress : nil, buffer.count, { _ in Task.isCancelled ? 1 : 0 }, nil)
                }
            }
            if status == NEANTIK_ZIP_CANCELLED { throw CancellationError() }
            guard status == NEANTIK_ZIP_OK else { throw CRXPackageInspectionError.archive }
            if isManifest { manifest = output }
            inventory.append(Entry(path: path, directory: directory, offset: offset, compressed: compressed,
                                   expanded: expanded, method: method, crc: crc))
            ranges.append((localOffset, recordEnd)); cursor += 46 + nameSize + extraSize + commentSize
            guard cursor <= end else { throw CRXPackageInspectionError.archive }
        }
        guard cursor == end else { throw CRXPackageInspectionError.archive }
        var expected = 0
        for range in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard range.0 == expected, range.1 > range.0 else { throw CRXPackageInspectionError.archive }; expected = range.1
        }
        guard expected == central else { throw CRXPackageInspectionError.archive }
        for path in names.keys {
            let parts = path.split(separator: "/").map(String.init)
            for n in 1..<parts.count where names[parts.prefix(n).joined(separator: "/")] == false {
                throw CRXPackageInspectionError.archive
            }
        }
        guard let manifest else { throw CRXPackageInspectionError.manifest }
        return .init(manifest: manifest, entries: count, expanded: expandedTotal, inventory: inventory)
    }
    private static func extra(_ data: Data) throws {
        var index = 0
        while index < data.count {
            guard data.count - index >= 4 else { throw CRXPackageInspectionError.archive }
            let id = data.crx16(index), count = Int(data.crx16(index + 2))
            guard ![1, 0x9901, 0x7075, 0x6375].contains(id), count <= data.count - index - 4 else { throw CRXPackageInspectionError.archive }
            index += 4 + count
        }
    }
}

private extension Data {
    func crx16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }
    func crx32(_ index: Int) -> UInt32 { UInt32(crx16(index)) | UInt32(crx16(index + 2)) << 16 }
}
