import Darwin
import Foundation

enum DevToolsSecurity {
    private static let maximumPortFileBytes = 4 * 1_024

    static func validatedWebSocketURL(
        _ value: String,
        expectedPort: Int,
        expectedPathPrefix: String
    ) -> URL? {
        guard (1...65_535).contains(expectedPort),
              let components = URLComponents(string: value),
              components.scheme == "ws",
              components.host == "127.0.0.1",
              components.port == expectedPort,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == components.path,
              components.path.hasPrefix(expectedPathPrefix)
        else {
            return nil
        }
        let identifier = components.path.dropFirst(
            expectedPathPrefix.count
        )
        guard !identifier.isEmpty,
              identifier.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) ||
                      (65...90).contains(byte) ||
                      (97...122).contains(byte) ||
                      byte == 45 || byte == 46 || byte == 95
              })
        else {
            return nil
        }
        return components.url
    }

    static func readPort(at url: URL) throws -> Int? {
        guard url.isFileURL else {
            throw NeAntikError.fingerprintAuditFailed(
                "DevTools port должен быть локальным файлом."
            )
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw NeAntikError.fingerprintAuditFailed(
                "DevTools port нельзя безопасно открыть."
            )
        }
        defer { Darwin.close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_uid == geteuid(),
              initial.st_nlink == 1,
              initial.st_size >= 0,
              initial.st_size <= Int64(maximumPortFileBytes)
        else {
            throw NeAntikError.fingerprintAuditFailed(
                "DevTools port имеет небезопасный тип или размер."
            )
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(
            min(Int(initial.st_size), maximumPortFileBytes)
        )
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while bytes.count <= maximumPortFileBytes {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress,
                    min(
                        rawBuffer.count,
                        maximumPortFileBytes + 1 - bytes.count
                    )
                )
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw NeAntikError.fingerprintAuditFailed(
                    "DevTools port не удалось безопасно прочитать."
                )
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count <= maximumPortFileBytes else {
            throw NeAntikError.fingerprintAuditFailed(
                "DevTools port превышает безопасный размер."
            )
        }

        var final = stat()
        var pathState = stat()
        guard fstat(descriptor, &final) == 0,
              lstat(url.path, &pathState) == 0,
              initial.st_dev == final.st_dev,
              initial.st_ino == final.st_ino,
              final.st_dev == pathState.st_dev,
              final.st_ino == pathState.st_ino,
              (pathState.st_mode & S_IFMT) == S_IFREG,
              final.st_uid == geteuid(),
              final.st_nlink == 1,
              final.st_size >= 0,
              final.st_size <= Int64(maximumPortFileBytes)
        else {
            throw NeAntikError.fingerprintAuditFailed(
                "DevTools port изменился во время чтения."
            )
        }
        guard initial.st_size == final.st_size,
              bytes.count == Int(final.st_size)
        else {
            // Chromium may create the file immediately before writing it.
            return nil
        }
        guard !bytes.isEmpty else { return nil }
        guard let contents = String(bytes: bytes, encoding: .utf8),
              !contents.contains("\0"),
              let firstLine = contents
                .split(whereSeparator: \.isNewline)
                .first,
              let port = Int(firstLine),
              (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }
}
