import Darwin
import Foundation

struct BrowserProcessArguments: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
}

fileprivate struct BrowserProcessInventoryEntry: Sendable {
    let executablePath: String
    let browserDataPaths: Set<String>

    var retainedByteCount: Int {
        executablePath.utf8.count +
            browserDataPaths.reduce(0) { $0 + $1.utf8.count }
    }
}

struct BrowserProcessKernelIdentity: Equatable, Sendable {
    let startSeconds: Int64
    let startMicroseconds: Int32
}

enum BrowserProcessArgumentParser {
    static let maximumArgumentCount = 4_096

    static func decode(
        _ buffer: [UInt8],
        byteCount: Int
    ) -> BrowserProcessArguments? {
        let headerSize = MemoryLayout<Int32>.size
        guard byteCount > headerSize,
              byteCount <= buffer.count
        else {
            return nil
        }

        var argumentCount = Int32()
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            destination.copyBytes(from: buffer.prefix(headerSize))
        }
        guard argumentCount > 0,
              argumentCount <= maximumArgumentCount,
              Int(argumentCount) <= byteCount - headerSize
        else {
            return nil
        }

        var index = headerSize
        guard let executablePath = readNullTerminatedString(
            buffer,
            byteCount: byteCount,
            index: &index
        ), !executablePath.isEmpty
        else {
            return nil
        }
        while index < byteCount, buffer[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        for _ in 0..<Int(argumentCount) {
            guard let argument = readNullTerminatedString(
                buffer,
                byteCount: byteCount,
                index: &index
            ) else {
                return nil
            }
            arguments.append(argument)
        }
        return BrowserProcessArguments(
            executablePath: executablePath,
            arguments: arguments
        )
    }

    private static func readNullTerminatedString(
        _ buffer: [UInt8],
        byteCount: Int,
        index: inout Int
    ) -> String? {
        guard index < byteCount else {
            return nil
        }
        let start = index
        while index < byteCount, buffer[index] != 0 {
            index += 1
        }
        guard index < byteCount,
              let value = String(
                  bytes: buffer[start..<index],
                  encoding: .utf8
              )
        else {
            return nil
        }
        index += 1
        return value
    }
}

struct BrowserProcessInventory: Sendable {
    private let processes: [pid_t: BrowserProcessInventoryEntry]
    private let kernelIdentities:
        [pid_t: BrowserProcessKernelIdentity]
    private let kernelIdentityRevalidator:
        @Sendable (pid_t) -> BrowserProcessKernelIdentity?
    private let unreadableLiveProcessExists: Bool
    private let available: Bool

    init(
        processes: [pid_t: BrowserProcessArguments],
        kernelIdentities:
            [pid_t: BrowserProcessKernelIdentity] = [:],
        kernelIdentityRevalidator:
            @escaping @Sendable
                (pid_t) -> BrowserProcessKernelIdentity? = { _ in nil },
        unreadableLiveProcessExists: Bool = false,
        available: Bool = true
    ) {
        var reduced: [pid_t: BrowserProcessInventoryEntry] = [:]
        var unsafePathExists = false
        for (pid, process) in processes {
            let extraction = Self.extractBrowserDataPaths(
                from: process.arguments
            )
            reduced[pid] = BrowserProcessInventoryEntry(
                executablePath: URL(
                    fileURLWithPath: process.executablePath
                ).standardizedFileURL.path,
                browserDataPaths: extraction.paths
            )
            unsafePathExists =
                unsafePathExists || extraction.unsafePathExists
        }
        self.processes = reduced
        self.kernelIdentities = kernelIdentities
        self.kernelIdentityRevalidator = kernelIdentityRevalidator
        self.unreadableLiveProcessExists =
            unreadableLiveProcessExists || unsafePathExists
        self.available = available
    }

    fileprivate init(
        reducedProcesses: [pid_t: BrowserProcessInventoryEntry],
        kernelIdentities:
            [pid_t: BrowserProcessKernelIdentity],
        kernelIdentityRevalidator:
            @escaping @Sendable
                (pid_t) -> BrowserProcessKernelIdentity?,
        unreadableLiveProcessExists: Bool,
        available: Bool
    ) {
        processes = reducedProcesses
        self.kernelIdentities = kernelIdentities
        self.kernelIdentityRevalidator = kernelIdentityRevalidator
        self.unreadableLiveProcessExists = unreadableLiveProcessExists
        self.available = available
    }

    static let unavailable = BrowserProcessInventory(
        reducedProcesses: [:],
        kernelIdentities: [:],
        kernelIdentityRevalidator: { _ in nil },
        unreadableLiveProcessExists: true,
        available: false
    )

    func inspectProcess(
        _ lock: BrowserProcessLock
    ) -> BrowserProcessIdentityInspection {
        guard DarwinBrowserProcessInventoryProvider.isProcessAlive(
            lock.pid
        ) else {
            return .unrelated
        }
        guard available else {
            return .unknown
        }
        guard let process = processes[lock.pid] else {
            return .unknown
        }
        if let capturedIdentity = kernelIdentities[lock.pid],
           kernelIdentityRevalidator(lock.pid) != capturedIdentity
        {
            return .unknown
        }
        let expectedExecutable = URL(
            fileURLWithPath: lock.executablePath
        ).standardizedFileURL.path
        let expectedBrowserDataPath = URL(
            fileURLWithPath: lock.browserDataPath
        ).standardizedFileURL.path
        guard process.executablePath == expectedExecutable,
              process.browserDataPaths.contains(expectedBrowserDataPath)
        else {
            return .unrelated
        }
        return .expected
    }

    func inspectBrowserDataProcess(
        _ browserDataDirectory: URL
    ) -> BrowserDataProcessInspection {
        guard available else {
            return .unknown
        }
        let expectedPath =
            browserDataDirectory.standardizedFileURL.path
        if processes.values.contains(where: {
            $0.browserDataPaths.contains(expectedPath)
        }) {
            return .found
        }
        return unreadableLiveProcessExists ? .unknown : .absent
    }

    fileprivate static func reducedEntry(
        from process: BrowserProcessArguments
    ) -> (
        entry: BrowserProcessInventoryEntry,
        unsafePathExists: Bool
    ) {
        let extraction = extractBrowserDataPaths(from: process.arguments)
        return (
            BrowserProcessInventoryEntry(
                executablePath: URL(
                    fileURLWithPath: process.executablePath
                ).standardizedFileURL.path,
                browserDataPaths: extraction.paths
            ),
            extraction.unsafePathExists
        )
    }

    private static func extractBrowserDataPaths(
        from arguments: [String]
    ) -> (paths: Set<String>, unsafePathExists: Bool) {
        let prefix = "--user-data-dir="
        var paths = Set<String>()
        var unsafePathExists = false
        for argument in arguments {
            guard argument == "--user-data-dir" ||
                    argument.hasPrefix(prefix)
            else {
                continue
            }
            guard argument.hasPrefix(prefix) else {
                unsafePathExists = true
                continue
            }
            let value = String(argument.dropFirst(prefix.count))
            guard !value.isEmpty,
                  value.hasPrefix("/")
            else {
                unsafePathExists = true
                continue
            }
            paths.insert(
                URL(fileURLWithPath: value).standardizedFileURL.path
            )
        }
        return (paths, unsafePathExists)
    }
}

final class BrowserProcessInventoryCaptureCoordinator:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let provider:
        @Sendable () -> BrowserProcessInventory

    init(
        provider:
            @escaping @Sendable () -> BrowserProcessInventory
    ) {
        self.provider = provider
    }

    func capture() -> BrowserProcessInventory {
        lock.lock()
        defer { lock.unlock() }
        return provider()
    }
}

final class DarwinBrowserProcessInventoryProvider: @unchecked Sendable {
    static let maximumProcessArgumentBytes = 4 * 1_024 * 1_024
    static let maximumProcessTableBytes = 64 * 1_024 * 1_024
    static let maximumProcessCount = 65_536
    static let maximumRetainedInventoryBytes = 8 * 1_024 * 1_024
    private let captureLock = NSLock()

    func capture() -> BrowserProcessInventory {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard let processIdentities = sameUserProcessIdentities(),
              let argumentBufferCapacity = processArgumentBufferCapacity()
        else {
            return .unavailable
        }

        var buffer = [UInt8](
            repeating: 0,
            count: argumentBufferCapacity
        )
        var processes: [pid_t: BrowserProcessInventoryEntry] = [:]
        processes.reserveCapacity(processIdentities.count)
        var retainedKernelIdentities:
            [pid_t: BrowserProcessKernelIdentity] = [:]
        retainedKernelIdentities.reserveCapacity(
            processIdentities.count
        )
        var unreadableLiveProcessExists = false
        var retainedBytes = 0
        for (pid, capturedIdentity) in processIdentities
            where pid != getpid()
        {
            guard let process = processArguments(
                pid: pid,
                reusing: &buffer
            ) else {
                if Self.isProcessAlive(pid) {
                    unreadableLiveProcessExists = true
                }
                continue
            }
            guard Self.currentProcessIdentity(pid) ==
                    capturedIdentity
            else {
                if Self.isProcessAlive(pid) {
                    unreadableLiveProcessExists = true
                }
                continue
            }
            let reduced = BrowserProcessInventory.reducedEntry(
                from: process
            )
            retainedBytes += reduced.entry.retainedByteCount
            guard retainedBytes <= Self.maximumRetainedInventoryBytes else {
                return .unavailable
            }
            processes[pid] = reduced.entry
            retainedKernelIdentities[pid] = capturedIdentity
            unreadableLiveProcessExists =
                unreadableLiveProcessExists ||
                reduced.unsafePathExists
        }
        return BrowserProcessInventory(
            reducedProcesses: processes,
            kernelIdentities: retainedKernelIdentities,
            kernelIdentityRevalidator: { pid in
                Self.currentProcessIdentity(pid)
            },
            unreadableLiveProcessExists: unreadableLiveProcessExists,
            available: true
        )
    }

    static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func sameUserProcessIdentities()
        -> [pid_t: BrowserProcessKernelIdentity]?
    {
        var managementInformationBase = [
            CTL_KERN,
            KERN_PROC,
            KERN_PROC_UID,
            Int32(getuid())
        ]
        var requiredBytes = 0
        guard managementInformationBase.withUnsafeMutableBufferPointer({
            sysctl(
                $0.baseAddress,
                u_int($0.count),
                nil,
                &requiredBytes,
                nil,
                0
            )
        }) == 0,
            requiredBytes > 0,
            requiredBytes <= Self.maximumProcessTableBytes
        else {
            return nil
        }

        let entrySize = MemoryLayout<kinfo_proc>.stride
        let requiredCount = requiredBytes / entrySize
        guard requiredCount <= Self.maximumProcessCount else {
            return nil
        }
        let capacity = min(
            requiredCount + 32,
            Self.maximumProcessCount
        )
        var entries = [kinfo_proc](
            repeating: kinfo_proc(),
            count: capacity
        )
        var actualBytes = entries.count * entrySize
        let readResult = managementInformationBase
            .withUnsafeMutableBufferPointer { base in
                entries.withUnsafeMutableBytes { bytes in
                    sysctl(
                        base.baseAddress,
                        u_int(base.count),
                        bytes.baseAddress,
                        &actualBytes,
                        nil,
                        0
                    )
                }
            }
        guard readResult == 0,
              actualBytes >= entrySize,
              actualBytes <= entries.count * entrySize,
              actualBytes.isMultiple(of: entrySize)
        else {
            return nil
        }
        var identities: [pid_t: BrowserProcessKernelIdentity] = [:]
        for entry in entries.prefix(actualBytes / entrySize) {
            let pid = entry.kp_proc.p_pid
            guard pid > 0 else { continue }
            identities[pid] = Self.kernelIdentity(for: entry)
        }
        guard identities[getpid()] != nil else {
            return nil
        }
        return identities
    }

    static func currentProcessIdentity(
        _ pid: pid_t
    ) -> BrowserProcessKernelIdentity? {
        guard pid > 0 else { return nil }
        var managementInformationBase = [
            CTL_KERN,
            KERN_PROC,
            KERN_PROC_PID,
            pid
        ]
        var entry = kinfo_proc()
        var byteCount = MemoryLayout<kinfo_proc>.stride
        let result = managementInformationBase
            .withUnsafeMutableBufferPointer { base in
                withUnsafeMutableBytes(of: &entry) { bytes in
                    sysctl(
                        base.baseAddress,
                        u_int(base.count),
                        bytes.baseAddress,
                        &byteCount,
                        nil,
                        0
                    )
                }
            }
        guard result == 0,
              byteCount == MemoryLayout<kinfo_proc>.stride,
              entry.kp_proc.p_pid == pid
        else {
            return nil
        }
        return kernelIdentity(for: entry)
    }

    private static func kernelIdentity(
        for entry: kinfo_proc
    ) -> BrowserProcessKernelIdentity {
        BrowserProcessKernelIdentity(
            startSeconds: Int64(
                entry.kp_proc.p_starttime.tv_sec
            ),
            startMicroseconds: Int32(
                entry.kp_proc.p_starttime.tv_usec
            )
        )
    }

    private func processArgumentBufferCapacity() -> Int? {
        var argumentMaximum = Int32()
        var argumentMaximumSize = MemoryLayout<Int32>.size
        guard sysctlbyname(
            "kern.argmax",
            &argumentMaximum,
            &argumentMaximumSize,
            nil,
            0
        ) == 0,
            argumentMaximum > MemoryLayout<Int32>.size
        else {
            return nil
        }
        return min(
            Int(argumentMaximum),
            Self.maximumProcessArgumentBytes
        )
    }

    private func processArguments(
        pid: pid_t,
        reusing buffer: inout [UInt8]
    ) -> BrowserProcessArguments? {
        Self.securelyScrub(&buffer)
        defer {
            Self.securelyScrub(&buffer)
        }
        var bufferSize = buffer.count
        var managementInformationBase = [
            CTL_KERN,
            KERN_PROCARGS2,
            pid
        ]
        let readResult = managementInformationBase
            .withUnsafeMutableBufferPointer { base in
                buffer.withUnsafeMutableBytes { bytes in
                    sysctl(
                        base.baseAddress,
                        u_int(base.count),
                        bytes.baseAddress,
                        &bufferSize,
                        nil,
                        0
                    )
                }
            }
        guard readResult == 0,
              bufferSize > MemoryLayout<Int32>.size,
              bufferSize <= buffer.count
        else {
            return nil
        }
        return BrowserProcessArgumentParser.decode(
            buffer,
            byteCount: bufferSize
        )
    }

    @inline(never)
    private static func securelyScrub(_ buffer: inout [UInt8]) {
        buffer.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            _ = Darwin.memset_s(
                baseAddress,
                bytes.count,
                0,
                bytes.count
            )
        }
    }
}
