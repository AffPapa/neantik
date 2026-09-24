import Darwin
import Foundation

/// Reads and validates user-selected transfer files without blocking AppKit's
/// main actor. The caller must keep any security-scoped URL access active until
/// this async operation returns.
enum ProfileConfigurationTransferFileImportService {
    static func readDocument(
        from url: URL,
        maximumBytes: Int
    ) async throws -> ProfileConfigurationTransferDocument {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try readBoundedRegularFile(
                from: url,
                maximumBytes: maximumBytes
            )
            try Task.checkCancellation()
            do {
                let document = try JSONDecoder().decode(
                    ProfileConfigurationTransferDocument.self,
                    from: data
                )
                try Task.checkCancellation()
                return document
            } catch let error as ProfileConfigurationTransferError {
                throw error
            } catch {
                throw ProfileConfigurationTransferFileError.invalidFile
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func readEncryptedDocument(
        from url: URL,
        maximumBytes: Int,
        passphrase: String
    ) async throws -> ProfileConfigurationTransferDocument {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try readBoundedRegularFile(
                    from: url,
                    maximumBytes: maximumBytes
                )
            } catch ProfileConfigurationTransferFileError.fileTooLarge {
                throw ProfileConfigurationEncryptionError.fileTooLarge
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProfileConfigurationEncryptionError.invalidEnvelope
            }
            try Task.checkCancellation()
            let document = try ProfileConfigurationEncryption.open(
                data,
                passphrase: passphrase
            )
            try Task.checkCancellation()
            return document
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func readBoundedRegularFile(
        from url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard url.isFileURL, maximumBytes >= 0 else {
            throw ProfileConfigurationTransferFileError.invalidFile
        }

        var coordinatedData: Data?
        var coordinationError: NSError?
        var operationError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                coordinatedData = try readRegularFileDescriptor(
                    at: coordinatedURL,
                    maximumBytes: maximumBytes
                )
            } catch {
                operationError = error
            }
        }

        if let operationError {
            throw operationError
        }
        if coordinationError != nil {
            throw ProfileConfigurationTransferFileError.invalidFile
        }
        guard let coordinatedData else {
            throw ProfileConfigurationTransferFileError.invalidFile
        }
        return coordinatedData
    }

    private static func readRegularFileDescriptor(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ProfileConfigurationTransferFileError.invalidFile
        }
        defer { Darwin.close(descriptor) }

        var fileInfo = stat()
        guard Darwin.fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw ProfileConfigurationTransferFileError.invalidFile
        }
        if fileInfo.st_size > maximumBytes {
            throw ProfileConfigurationTransferFileError.fileTooLarge
        }

        var data = Data()
        let detectionLimit = maximumBytes.addingReportingOverflow(1)
        guard !detectionLimit.overflow else {
            throw ProfileConfigurationTransferFileError.fileTooLarge
        }
        while data.count < detectionLimit.partialValue {
            try Task.checkCancellation()
            let count = min(64 * 1_024, detectionLimit.partialValue - data.count)
            var buffer = [UInt8](repeating: 0, count: count)
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw ProfileConfigurationTransferFileError.invalidFile
            }
            if bytesRead == 0 { break }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        guard data.count <= maximumBytes else {
            throw ProfileConfigurationTransferFileError.fileTooLarge
        }
        return data
    }
}
