import Darwin
import DirectZipCodec
import Foundation

enum DirectUpdateZIPError: Error { case malformed, unsupported, unsafePath, collision, limit, changed, checksum, codec, write }

/// A bounded ZIP32 reader for the Direct package contract, not a general ZIP
/// importer. No ZIP64, encryption, split archives, SFX, xattrs or special files.
struct DirectUpdateZIPInventory {
    enum Kind: Sendable { case file, directory, symlink }
    struct Entry: Sendable {
        let path: String, kind: Kind, mode: mode_t
        let dataOffset: Int64, compressed: Int64, expanded: Int64
        let method: UInt16, crc: UInt32, target: String?
    }
    let entries: [Entry]
    let expandedBytes: Int64
    static let maximumEntries = 50_000, maximumPathBytes = 1_024
    static let maximumExpandedBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    static func read(_ fd: Int32) throws -> Self {
        let original = try BackupFS.identity(fd)
        try original.validateFile(device: nil)
        guard original.size >= 22, original.size <= DirectUpdateArchiveIntegrityService.maximumArchiveBytes else { throw DirectUpdateZIPError.limit }
        func bytes(_ offset: Int64, _ count: Int) throws -> Data {
            try Task.checkCancellation()
            guard count >= 0, offset >= 0, Int64(count) <= original.size - offset else { throw DirectUpdateZIPError.malformed }
            let data = try BackupFS.read(fd, at: offset, count: count)
            guard data.count == count else { throw DirectUpdateZIPError.changed }
            return data
        }
        let tailSize = Int(min(original.size, 65_557)), tailStart = original.size - Int64(tailSize)
        let tail = try bytes(tailStart, tailSize)
        var ends: [Int] = []
        for index in 0...(tail.count - 22) where tail.u32(index) == 0x06054b50 {
            if index + 22 + Int(tail.u16(index + 20)) == tail.count { ends.append(index) }
        }
        guard ends.count == 1, let end = ends.first else { throw DirectUpdateZIPError.malformed }
        let endOffset = tailStart + Int64(end), count = Int(tail.u16(end + 10))
        let centralSize = Int64(tail.u32(end + 12)), centralOffset = Int64(tail.u32(end + 16))
        guard tail.u16(end + 4) == 0, tail.u16(end + 6) == 0, Int(tail.u16(end + 8)) == count,
              count > 0, count < 65_535, count <= maximumEntries,
              centralSize > 0, centralSize <= 32 * 1_024 * 1_024,
              centralOffset > 0, centralOffset + centralSize == endOffset else { throw DirectUpdateZIPError.unsupported }
        var entries: [Entry] = [], ranges: [(Int64, Int64)] = []
        var cursor = centralOffset, total: Int64 = 0
        var paths: [String: Kind] = [:], canonical: [String: String] = [:]
        for _ in 0..<count {
            let header = try bytes(cursor, 46)
            guard header.u32(0) == 0x02014b50 else { throw DirectUpdateZIPError.malformed }
            let needed = header.u16(6), flags = header.u16(8), method = header.u16(10), crc = header.u32(16)
            let compressed = Int64(header.u32(20)), expanded = Int64(header.u32(24))
            let nameSize = Int(header.u16(28)), extraSize = Int(header.u16(30)), commentSize = Int(header.u16(32))
            let mode = mode_t(header.u32(38) >> 16), localOffset = Int64(header.u32(42))
            guard needed <= 20, header.u16(34) == 0, header[5] == 3,
                  flags & ~UInt16(0x0808) == 0, method == 0 || method == 8,
                  compressed < Int64(UInt32.max), expanded < Int64(UInt32.max), localOffset < centralOffset,
                  nameSize > 0, nameSize <= maximumPathBytes, mode & 0o7000 == 0 else { throw DirectUpdateZIPError.unsupported }
            let variable = try bytes(cursor + 46, nameSize + extraSize + commentSize)
            try checkExtra(Data(variable[nameSize..<(nameSize + extraSize)]))
            let rawName = Data(variable.prefix(nameSize))
            guard let name = String(data: rawName, encoding: .utf8) else { throw DirectUpdateZIPError.unsafePath }
            let type = mode & mode_t(S_IFMT), kind: Kind
            switch type {
            case mode_t(S_IFREG): kind = .file
            case mode_t(S_IFDIR): kind = .directory
            case mode_t(S_IFLNK): kind = .symlink
            default: throw DirectUpdateZIPError.unsupported
            }
            guard name.hasSuffix("/") == (kind == .directory) else { throw DirectUpdateZIPError.unsafePath }
            let path = kind == .directory ? String(name.dropLast()) : name
            try checkPath(path)
            guard paths[path] == nil else { throw DirectUpdateZIPError.collision }
            paths[path] = kind
            let components = path.split(separator: "/").map(String.init)
            for prefixSize in 1...components.count {
                let prefix = components.prefix(prefixSize).joined(separator: "/")
                let key = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard canonical[key] == nil || canonical[key] == prefix else { throw DirectUpdateZIPError.collision }
                canonical[key] = prefix
            }
            let local = try bytes(localOffset, 30)
            guard local.u32(0) == 0x04034b50, local.u16(4) == needed, local.u16(6) == flags,
                  local.u16(8) == method, Int(local.u16(26)) == nameSize else { throw DirectUpdateZIPError.malformed }
            let localExtraSize = Int(local.u16(28))
            let localVariable = try bytes(localOffset + 30, nameSize + localExtraSize)
            guard Data(localVariable.prefix(nameSize)) == rawName else { throw DirectUpdateZIPError.malformed }
            try checkExtra(Data(localVariable.dropFirst(nameSize)))
            let dataOffset = localOffset + 30 + Int64(nameSize + localExtraSize)
            var recordEnd = dataOffset + compressed
            guard recordEnd <= centralOffset else { throw DirectUpdateZIPError.malformed }
            if flags & 8 == 0 {
                guard local.u32(14) == crc, Int64(local.u32(18)) == compressed, Int64(local.u32(22)) == expanded else { throw DirectUpdateZIPError.malformed }
            } else {
                guard [0, crc].contains(local.u32(14)), [0, compressed].contains(Int64(local.u32(18))),
                      [0, expanded].contains(Int64(local.u32(22))) else { throw DirectUpdateZIPError.malformed }
                let prefix = try bytes(recordEnd, 4), signed = prefix.u32(0) == 0x08074b50
                let descriptor = try bytes(recordEnd, signed ? 16 : 12), base = signed ? 4 : 0
                guard descriptor.u32(base) == crc, Int64(descriptor.u32(base + 4)) == compressed,
                      Int64(descriptor.u32(base + 8)) == expanded else { throw DirectUpdateZIPError.malformed }
                recordEnd += signed ? 16 : 12
            }
            var target: String?
            if kind == .directory {
                guard method == 0, compressed == 0, expanded == 0, crc == 0 else { throw DirectUpdateZIPError.malformed }
            } else if kind == .symlink {
                guard method == 0, compressed == expanded, expanded > 0, expanded <= 1_024 else { throw DirectUpdateZIPError.unsupported }
                let data = try bytes(dataOffset, Int(expanded))
                guard data.withUnsafeBytes({ neantik_zip_crc32($0.baseAddress, $0.count) }) == crc,
                      let link = String(data: data, encoding: .utf8), !link.isEmpty else { throw DirectUpdateZIPError.checksum }
                target = link
            }
            guard expanded <= maximumExpandedBytes - total else { throw DirectUpdateZIPError.limit }
            total += expanded
            entries.append(.init(path: path, kind: kind, mode: mode & 0o777, dataOffset: dataOffset,
                                 compressed: compressed, expanded: expanded, method: method, crc: crc, target: target))
            ranges.append((localOffset, recordEnd)); cursor += 46 + Int64(nameSize + extraSize + commentSize)
            guard cursor <= endOffset else { throw DirectUpdateZIPError.malformed }
        }
        guard cursor == endOffset else { throw DirectUpdateZIPError.malformed }
        var expected: Int64 = 0
        for range in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard range.0 == expected, range.1 > range.0 else { throw DirectUpdateZIPError.malformed }; expected = range.1
        }
        guard expected == centralOffset, paths["NeAntik.app"] == .directory else { throw DirectUpdateZIPError.unsafePath }
        let links = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.target.map { (entry.path, $0) } })
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            for n in 1..<parts.count {
                guard paths[parts.prefix(n).joined(separator: "/")] == .directory else { throw DirectUpdateZIPError.unsafePath }
            }
            if let target = entry.target {
                try resolveLink(parent: parts.dropLast().joined(separator: "/"), target: target, links: links, paths: paths)
            }
        }
        guard try BackupFS.identity(fd) == original else { throw DirectUpdateZIPError.changed }
        return .init(entries: entries, expandedBytes: total)
    }
    private static func checkPath(_ path: String) throws {
        guard path.utf8.count <= maximumPathBytes, path == path.precomposedStringWithCanonicalMapping,
              path == "NeAntik.app" || path.hasPrefix("NeAntik.app/"), !path.contains("//"),
              !path.hasSuffix("/"), path.split(separator: "/").count <= 32 else { throw DirectUpdateZIPError.unsafePath }
        for part in path.split(separator: "/") { try BackupFS.validateName(String(part)) }
    }
    private static func linkComponents(_ target: String) throws -> [String] {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"), !target.contains("//"), !target.hasSuffix("/"),
              target.utf8.count <= maximumPathBytes, target == target.precomposedStringWithCanonicalMapping
        else { throw DirectUpdateZIPError.unsafePath }
        return target.split(separator: "/").map(String.init)
    }
    /// Resolve links before processing following '..', as the filesystem does.
    /// Lexical normalization before link expansion would allow root escapes.
    private static func resolveLink(parent: String, target: String, links: [String: String], paths: [String: Kind]) throws {
        var parts = parent.split(separator: "/").map(String.init)
        var pending = try linkComponents(target), expanded = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == ".." { guard parts.count > 1 else { throw DirectUpdateZIPError.unsafePath }; parts.removeLast() }
            else if part != "." {
                try BackupFS.validateName(part); parts.append(part)
                let path = parts.joined(separator: "/")
                if let next = links[path] {
                    expanded += 1; guard expanded <= 32 else { throw DirectUpdateZIPError.unsafePath }
                    parts.removeLast(); pending = try linkComponents(next) + pending
                } else {
                    guard let kind = paths[path], kind != .symlink, pending.isEmpty || kind == .directory
                    else { throw DirectUpdateZIPError.unsafePath }
                }
            }
        }
        let path = parts.joined(separator: "/"); try checkPath(path)
        guard let kind = paths[path], kind != .symlink else { throw DirectUpdateZIPError.unsafePath }
    }
    private static func checkExtra(_ data: Data) throws {
        var cursor = 0
        while cursor < data.count {
            guard data.count - cursor >= 4 else { throw DirectUpdateZIPError.malformed }
            let id = data.u16(cursor), size = Int(data.u16(cursor + 2))
            guard id != 1, id != 0x9901, size <= data.count - cursor - 4 else { throw DirectUpdateZIPError.unsupported }
            cursor += 4 + size
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
