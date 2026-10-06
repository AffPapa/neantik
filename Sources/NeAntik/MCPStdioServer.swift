import Darwin
import CoreFoundation
import Foundation

/// Local, opt-in MCP transport. No socket, listener, account, or browser action.
/// The client explicitly selects a metadata root; output is an allowlist only.
enum MCPStdioServer {
    static let maximumRequestBytes = 64 * 1_024
    static let maximumProfilesFileBytes = 16 * 1_024 * 1_024
    static let protocolVersion = "2025-11-25"

    static func runAndExit(dataRoot: URL) -> Never {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
            }
            if count == 0 { Darwin.exit(EXIT_SUCCESS) }
            if count < 0 {
                if errno == EINTR { continue }
                Darwin.exit(EX_IOERR)
            }
            guard let lines = framedLines(
                pending: &pending, incoming: Data(buffer.prefix(count))
            ) else { Darwin.exit(EX_DATAERR) }
            for line in lines {
                if let response = handle(line, dataRoot: dataRoot) {
                    write(response)
                }
            }
        }
    }

    /// The cap belongs to each JSON-RPC line, not to a batch of valid lines.
    static func framedLines(pending: inout Data, incoming: Data) -> [Data]? {
        pending.append(incoming)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending.prefix(upTo: newline))
            guard line.count <= maximumRequestBytes else { return nil }
            pending.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard pending.count <= maximumRequestBytes else { return nil }
        return lines
    }

    static func handle(_ line: Data, dataRoot: URL) -> Data? {
        guard line.count <= maximumRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: line)
        else { return response(id: NSNull(), error: (-32700, "Parse error")) }
        guard
              let request = object as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String
        else { return response(id: NSNull(), error: (-32600, "Invalid request")) }
        if let id = request["id"], !isValidRequestID(id) {
            return response(id: NSNull(), error: (-32600, "Invalid request id"))
        }
        guard let id = request["id"] else { return nil }
        guard request["params"] == nil || request["params"] is [String: Any] else {
            return response(id: id, error: (-32602, "Invalid params"))
        }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return response(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "neantik-local", "version": "0.1"]
            ])
        case "ping":
            return response(id: id, result: [:])
        case "tools/list":
            return response(id: id, result: ["tools": [[
                "name": "workspace_list_profiles",
                "description": "List safe profile metadata from the selected local workspace. Running state, proxy endpoint, credentials, browser data, and fingerprint are unavailable.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
            ]]])
        case "tools/call":
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard params["name"] as? String == "workspace_list_profiles",
                  params["arguments"] == nil || params["arguments"] is [String: Any],
                  arguments.isEmpty
            else { return response(id: id, error: (-32602, "Unknown tool or arguments")) }
            do {
                let profiles = try readProfiles(dataRoot: dataRoot)
                let safeProfiles: [[String: Any]] = profiles.map { profile in
                    ["id": profile.id.uuidString,
                     "name": profile.name,
                     "tags": profile.tags,
                     "isPinned": profile.isPinned,
                     "isArchived": profile.isArchived,
                     "processState": "unverified"]
                }
                let payload: [String: Any] = [
                    "schemaVersion": 1,
                    "profiles": safeProfiles,
                    "count": safeProfiles.count
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                let text = String(decoding: data, as: UTF8.self)
                return response(id: id, result: ["content": [["type": "text", "text": text]]])
            } catch {
                // Never echo paths, file contents, or parser diagnostics to clients.
                return response(id: id, result: [
                    "isError": true,
                    "content": [["type": "text", "text": "Workspace metadata unavailable or requires recovery in NeAntik."]]
                ])
            }
        default:
            return response(id: id, error: (-32601, "Method not found"))
        }
    }

    private static func isValidRequestID(_ id: Any) -> Bool {
        if id is String || id is NSNull { return true }
        guard let number = id as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    private static func readProfiles(dataRoot: URL) throws -> [BrowserProfile] {
        let paths = AppPaths(rootDirectory: dataRoot)
        try paths.validatePrivateDirectory(dataRoot)
        let file = paths.profilesFile
        let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if descriptor < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0,
              status.st_size <= maximumProfilesFileBytes
        else { throw POSIXError(.EFTYPE) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumProfilesFileBytes + 1) ?? Data()
        guard data.count <= maximumProfilesFileBytes else { throw POSIXError(.EFBIG) }
        let profiles = try ProfileStore.decodeProfiles(data)
        let normalized = try ProfileStore.normalizedForIsolation(profiles)
        guard !normalized.changed else { throw POSIXError(.EINVAL) }
        return profiles
    }

    private static func response(
        id: Any,
        result: [String: Any]? = nil,
        error: (Int, String)? = nil
    ) -> Data? {
        var value: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { value["result"] = result }
        if let error { value["error"] = ["code": error.0, "message": error.1] }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return data + Data([0x0A])
    }

    private static func write(_ data: Data) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { Darwin.exit(EX_IOERR) }
                offset += written
            }
        }
    }
}
