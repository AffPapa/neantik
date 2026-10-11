import Darwin
import Foundation

package enum DirectUpdateStageError: Error { case unsafeDestination, changed, discarded }
package enum DirectUpdateStagePoint: Sendable {
    case created(URL), beforeChunkWrite(Int64), beforeFileSync, beforeDirectorySync, beforeParentSync, beforeReturn
    case beforeRetireDirectory(URL), beforeRetireArchive(URL)
}

/// Owned archive custody, not verified app/install authority. No decoding or
/// public receipt can manufacture this object. Extraction/trust must follow.
final package class PreparedUpdateArchive: @unchecked Sendable {
    package let integrity: UpdateArchiveIntegrityReceipt
    private let lock = NSLock()
    private let parentURL: URL, stageURL: URL
    private let parent: Int32, directory: Int32, file: Int32
    private let parentIdentity: BackupIdentity, directoryIdentity: BackupIdentity, fileIdentity: BackupIdentity
    private let name: String
    private var discarded = false

    fileprivate init(parentURL: URL, name: String, parent: Int32, directory: Int32, file: Int32,
                     parentIdentity: BackupIdentity, directoryIdentity: BackupIdentity,
                     fileIdentity: BackupIdentity, integrity: UpdateArchiveIntegrityReceipt) {
        self.parentURL = parentURL; self.name = name
        stageURL = parentURL.appendingPathComponent(name, isDirectory: true)
        self.parent = parent; self.directory = directory; self.file = file
        self.parentIdentity = parentIdentity; self.directoryIdentity = directoryIdentity; self.fileIdentity = fileIdentity
        self.integrity = integrity
    }
    deinit { Darwin.close(file); Darwin.close(directory); Darwin.close(parent) }

    /// The caller gets a path only while custody is validated and locked. Later
    /// stages must revalidate their own snapshots before publishing anything.
    package func withValidatedArchive<T>(_ operation: (URL, UpdateArchiveIntegrityReceipt) throws -> T) throws -> T {
        try withValidatedArchiveFile { _, url, integrity in try operation(url, integrity) }
    }
    /// Borrow the captured descriptor under the custody lock. The callback
    /// must not close it or reopen the namespace in place of this descriptor.
    package func withValidatedArchiveFile<T>(_ operation: (Int32, URL, UpdateArchiveIntegrityReceipt) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try validate()
        let result = try operation(file, stageURL.appendingPathComponent("archive.zip"), integrity)
        try validate()
        return result
    }
    private func validate() throws {
        guard !discarded else { throw DirectUpdateStageError.discarded }
        try BackupFS.validateDirectoryPath(parentURL, parentIdentity)
        let currentParent = try BackupFS.identity(parent)
        guard currentParent.sameObject(parentIdentity), currentParent.mode & 0o777 == 0o700,
              try BackupFS.entry(parent, name) == directoryIdentity,
              try BackupFS.identity(directory) == directoryIdentity,
              try BackupFS.names(directory) == ["archive.zip"],
              try BackupFS.identity(file) == fileIdentity,
              try BackupFS.entry(directory, "archive.zip") == fileIdentity
        else { throw DirectUpdateStageError.changed }
    }
    /// Explicit cleanup only, with captured inode checks. Unexpected objects
    /// are preserved and reported; deinit closes descriptors without deletion.
    package func discard(fault: (@Sendable (DirectUpdateStagePoint) throws -> Void)? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try validate()
        try DirectUpdateStageStorage.removeOwnedStage(parentURL: parentURL, parent: parent, name: name,
            directory: directory, directoryIdentity: directoryIdentity, fileIdentity: fileIdentity, fault: fault)
        discarded = true
        guard fsync(parent) == 0 else { throw BackupFS.posix() }
    }
}

/// One local archive is copied into a new private directory on the chosen
/// target volume. No network, extraction, app execution or installation.
package enum DirectUpdateStageStorage {
    package static func prepareLocalArchive(
        archiveURL: URL, signedManifest: Data, configuration: UpdateChannelConfiguration,
        installedVersion: String, installedBuild: Int, destinationParent: URL,
        hostOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        clock: @escaping @Sendable () -> Date = { Date() },
        byteLimit: Int64 = DirectUpdateArchiveIntegrityService.maximumArchiveBytes,
        fault: (@Sendable (DirectUpdateStagePoint) throws -> Void)? = nil
    ) async throws -> PreparedUpdateArchive {
        let worker = Task.detached(priority: .utility) {
            try prepareSynchronously(archiveURL: archiveURL, signedManifest: signedManifest, configuration: configuration,
                installedVersion: installedVersion, installedBuild: installedBuild, destinationParent: destinationParent,
                hostOS: hostOS, clock: clock, byteLimit: byteLimit, fault: fault)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    package static func prepareSynchronously(
        archiveURL: URL, signedManifest: Data, configuration: UpdateChannelConfiguration,
        installedVersion: String, installedBuild: Int, destinationParent: URL,
        hostOS: OperatingSystemVersion, clock: @Sendable () -> Date,
        byteLimit: Int64 = DirectUpdateArchiveIntegrityService.maximumArchiveBytes,
        fault: (@Sendable (DirectUpdateStagePoint) throws -> Void)? = nil
    ) throws -> PreparedUpdateArchive {
        try Task.checkCancellation()
        _ = try DirectUpdateArchiveIntegrityService.admittedManifest(signedManifest, configuration: configuration,
            installedVersion: installedVersion, installedBuild: installedBuild, hostOS: hostOS, now: clock())
        guard byteLimit > 0, byteLimit <= DirectUpdateArchiveIntegrityService.maximumArchiveBytes
        else { throw DirectUpdateArchiveIntegrityError.limitExceeded }
        let source = try DirectUpdateArchiveIntegrityService.platformFileURL(archiveURL)
        let destination = try DirectUpdateArchiveIntegrityService.platformFileURL(destinationParent)
        let scoped = archiveURL.startAccessingSecurityScopedResource()
        defer { if scoped { archiveURL.stopAccessingSecurityScopedResource() } }
        let sourceParentURL = source.deletingLastPathComponent(), sourceName = source.lastPathComponent
        try BackupFS.validateName(sourceName)
        let sourceParent = try BackupFS.directory(sourceParentURL)
        defer { Darwin.close(sourceParent) }
        let input = openat(sourceParent, sourceName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw DirectUpdateArchiveIntegrityError.unsafeFile }
        defer { Darwin.close(input) }
        let sourceParentIdentity = try BackupFS.identity(sourceParent), sourceIdentity = try BackupFS.identity(input)
        try sourceIdentity.validateFile(device: nil)
        guard sourceIdentity.size > 0, sourceIdentity.size <= byteLimit else { throw DirectUpdateArchiveIntegrityError.limitExceeded }
        func validateSource() throws {
            try BackupFS.validateDirectoryPath(sourceParentURL, sourceParentIdentity)
            guard try BackupFS.identity(input) == sourceIdentity,
                  try BackupFS.entry(sourceParent, sourceName) == sourceIdentity
            else { throw DirectUpdateArchiveIntegrityError.archiveChanged }
        }
        try validateSource()
        let parent = try BackupFS.directory(destination)
        var directory: Int32 = -1, output: Int32 = -1
        var transferred = false
        defer {
            if !transferred {
                if output >= 0 { Darwin.close(output) }
                if directory >= 0 { Darwin.close(directory) }
                Darwin.close(parent)
            }
        }
        let parentIdentity = try BackupFS.identity(parent)
        guard parentIdentity.mode & 0o777 == 0o700 else { throw DirectUpdateStageError.unsafeDestination }
        let name = ".neantik-update-stage-" + UUID().uuidString.lowercased()
        guard mkdirat(parent, name, 0o700) == 0 else { throw BackupFS.posix() }
        directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw DirectUpdateStageError.changed }
        let createdDirectory = try BackupFS.identity(directory)
        var createdFile: BackupIdentity?
        var finished = false
        // Retire by no-overwrite rename and validate what actually moved.
        // Unknown/replaced objects remain recoverable; no tree traversal.
        defer {
            if !finished {
                try? removeOwnedStage(parentURL: destination, parent: parent, name: name, directory: directory,
                    directoryIdentity: createdDirectory, fileIdentity: createdFile, fault: fault)
            }
        }
        guard createdDirectory.directory, createdDirectory.uid == geteuid(),
              createdDirectory.device == parentIdentity.device, createdDirectory.mode & 0o777 == 0o700
        else { throw DirectUpdateStageError.changed }
        output = openat(directory, "archive.zip", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw BackupFS.posix() }
        createdFile = try BackupFS.identity(output)
        let stageURL = destination.appendingPathComponent(name, isDirectory: true)
        func validateStage() throws {
            try BackupFS.validateDirectoryPath(destination, parentIdentity)
            let currentParent = try BackupFS.identity(parent), currentDirectory = try BackupFS.identity(directory)
            guard currentParent.sameObject(parentIdentity), currentParent.mode & 0o777 == 0o700,
                  try BackupFS.entry(parent, name)?.sameObject(createdDirectory) == true,
                  currentDirectory.sameObject(createdDirectory), currentDirectory.mode & 0o777 == 0o700,
                  try BackupFS.names(directory) == ["archive.zip"],
                  let actual = try BackupFS.entry(directory, "archive.zip"),
                  actual.sameObject(try BackupFS.identity(output)), actual.sameObject(createdFile!),
                  actual.links == 1, actual.uid == geteuid()
            else { throw DirectUpdateStageError.changed }
        }
        try fault?(.created(stageURL))
        var offset: Int64 = 0
        while offset < sourceIdentity.size {
            try Task.checkCancellation(); try validateSource(); try validateStage()
            let count = Int(min(65_536, sourceIdentity.size - offset))
            let bytes = try BackupFS.read(input, at: offset, count: count)
            guard bytes.count == count else { throw DirectUpdateArchiveIntegrityError.archiveChanged }
            try fault?(.beforeChunkWrite(offset))
            try BackupFS.write(output, bytes, at: offset); offset += Int64(count)
        }
        try validateSource(); try validateStage()
        guard fchmod(output, 0o400) == 0 else { throw BackupFS.posix() }
        try fault?(.beforeFileSync)
        guard fsync(output) == 0 else { throw BackupFS.posix() }
        try fault?(.beforeDirectorySync)
        guard fsync(directory) == 0 else { throw BackupFS.posix() }
        try fault?(.beforeParentSync)
        guard fsync(parent) == 0 else { throw BackupFS.posix() }
        let finalDirectory = try BackupFS.identity(directory), finalFile = try BackupFS.identity(output)
        // Hash the actual stage, not only bytes read from the mutable source.
        let integrity = try DirectUpdateArchiveIntegrityService.verifySynchronously(
            archiveURL: stageURL.appendingPathComponent("archive.zip"), signedManifest: signedManifest,
            configuration: configuration, installedVersion: installedVersion, installedBuild: installedBuild,
            hostOS: hostOS, clock: clock, byteLimit: byteLimit)
        guard finalFile.size == offset, finalFile.mode & 0o777 == 0o400 else { throw DirectUpdateStageError.changed }
        try fault?(.beforeReturn)
        try Task.checkCancellation(); try validateSource(); try validateStage()
        _ = try DirectUpdateArchiveIntegrityService.admittedManifest(signedManifest, configuration: configuration,
            installedVersion: installedVersion, installedBuild: installedBuild, hostOS: hostOS, now: clock())
        try Task.checkCancellation(); try validateSource(); try validateStage()
        guard try BackupFS.identity(directory) == finalDirectory, try BackupFS.identity(output) == finalFile
        else { throw DirectUpdateStageError.changed }
        let prepared = PreparedUpdateArchive(parentURL: destination, name: name, parent: parent, directory: directory,
            file: output, parentIdentity: parentIdentity, directoryIdentity: finalDirectory, fileIdentity: finalFile,
            integrity: integrity)
        finished = true; transferred = true
        return prepared
    }

    /// Narrow retirement of one captured directory/file. Rename guards the
    /// published names against replacement between inspection and removal.
    /// This is not a security boundary against arbitrary same-UID processes
    /// continuously rewriting private randomized retirement names.
    fileprivate static func removeOwnedStage(parentURL: URL, parent: Int32, name: String, directory: Int32,
                                             directoryIdentity: BackupIdentity, fileIdentity: BackupIdentity?,
                                             fault: (@Sendable (DirectUpdateStagePoint) throws -> Void)?) throws {
        guard try BackupFS.identity(directory).sameObject(directoryIdentity),
              try BackupFS.entry(parent, name)?.sameObject(directoryIdentity) == true
        else { throw DirectUpdateStageError.changed }
        let names = try BackupFS.names(directory)
        if let fileIdentity {
            guard names == ["archive.zip"], let current = try BackupFS.entry(directory, "archive.zip"),
                  current.sameObject(fileIdentity), current.links == 1 else { throw DirectUpdateStageError.changed }
        } else { guard names.isEmpty else { throw DirectUpdateStageError.changed } }
        let retired = ".neantik-update-retiring-" + UUID().uuidString.lowercased()
        try fault?(.beforeRetireDirectory(parentURL.appendingPathComponent(name)))
        guard renameatx_np(parent, name, parent, retired, UInt32(RENAME_EXCL)) == 0 else { throw BackupFS.posix() }
        guard try BackupFS.entry(parent, retired)?.sameObject(directoryIdentity) == true else {
            // Restore the unexpected object only if the old name is still free.
            _ = renameatx_np(parent, retired, parent, name, UInt32(RENAME_EXCL))
            _ = fsync(parent)
            throw DirectUpdateStageError.changed
        }
        guard try BackupFS.identity(directory).sameObject(directoryIdentity) else { throw DirectUpdateStageError.changed }
        if let fileIdentity {
            let retiredFile = ".retiring-archive-" + UUID().uuidString.lowercased()
            try fault?(.beforeRetireArchive(parentURL.appendingPathComponent(retired).appendingPathComponent("archive.zip")))
            guard renameatx_np(directory, "archive.zip", directory, retiredFile, UInt32(RENAME_EXCL)) == 0 else { throw BackupFS.posix() }
            guard let current = try BackupFS.entry(directory, retiredFile), current.sameObject(fileIdentity), current.links == 1,
                  try BackupFS.names(directory) == [retiredFile] else {
                _ = fsync(directory); _ = fsync(parent)
                throw DirectUpdateStageError.changed
            }
            guard unlinkat(directory, retiredFile, 0) == 0 else { throw BackupFS.posix() }
        }
        guard try BackupFS.names(directory).isEmpty else { throw DirectUpdateStageError.changed }
        guard unlinkat(parent, retired, AT_REMOVEDIR) == 0 else { throw BackupFS.posix() }
        guard fsync(parent) == 0 else { throw BackupFS.posix() }
    }
}
