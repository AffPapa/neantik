import CryptoKit
import Darwin
import Foundation

package enum DirectUpdateDownloadError: Error { case response, redirect, integrity, limit, custody }

/// Private, bounded download custody; never an installation authority.
package final class DownloadedUpdateArchive: @unchecked Sendable {
    package let url: URL
    private let directory: URL
    private let parent: Int32, file: Int32
    private let directoryIdentity: BackupIdentity, fileIdentity: BackupIdentity
    private let lock = NSLock()
    private var disposed = false
    init() throws {
        var template = Array("/private/tmp/neantik-update-download.XXXXXX".utf8CString)
        guard let value = mkdtemp(&template) else { throw BackupFS.posix() }
        let directory = URL(fileURLWithPath: String(cString: value), isDirectory: true)
        var initial = stat()
        guard lstat(directory.path, &initial) == 0 else { throw BackupFS.posix() }
        let initialIdentity = BackupIdentity(initial)
        var parentFD: Int32 = -1, fileFD: Int32 = -1
        var ownedFileIdentity: BackupIdentity?, transferred = false
        defer {
            if !transferred {
                if parentFD >= 0, let identity = ownedFileIdentity,
                   (try? BackupFS.entry(parentFD, "update.zip")?.sameObject(identity)) == true { _ = unlinkat(parentFD, "update.zip", 0) }
                if fileFD >= 0 { Darwin.close(fileFD) }
                if parentFD >= 0 { Darwin.close(parentFD) }
                if (try? BackupFS.validateDirectoryPath(directory, initialIdentity)) != nil { _ = rmdir(directory.path) }
            }
        }
        parentFD = try BackupFS.directory(directory)
        let directoryIdentity = try BackupFS.identity(parentFD)
        guard directoryIdentity.sameObject(initialIdentity) else { throw DirectUpdateDownloadError.custody }
        let url = directory.appendingPathComponent("update.zip")
        fileFD = openat(parentFD, "update.zip", O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileFD >= 0 else { throw BackupFS.posix() }
        let fileIdentity = try BackupFS.identity(fileFD); ownedFileIdentity = fileIdentity
        self.directory = directory; self.url = url; self.parent = parentFD; self.file = fileFD
        self.directoryIdentity = directoryIdentity; self.fileIdentity = fileIdentity; transferred = true
    }
    func append(_ data: Data, offset: Int64) throws {
        try validate(); try BackupFS.write(file, data, at: offset)
    }
    func finish() throws { try validate(); guard fsync(file) == 0 else { throw BackupFS.posix() } }
    package func validate() throws {
        try BackupFS.validateDirectoryPath(directory, directoryIdentity)
        guard try BackupFS.entry(parent, "update.zip")?.sameObject(fileIdentity) == true,
              try BackupFS.identity(file).sameObject(fileIdentity) else { throw DirectUpdateDownloadError.custody }
    }
    package func dispose() {
        lock.lock(); defer { lock.unlock() }
        guard !disposed else { return }; disposed = true
        // Refuse a replacement; never recursively remove a path we no longer own.
        if (try? BackupFS.entry(parent, "update.zip")?.sameObject(fileIdentity)) == true { _ = unlinkat(parent, "update.zip", 0) }
        if (try? BackupFS.validateDirectoryPath(directory, directoryIdentity)) != nil { _ = rmdir(directory.path) }
        Darwin.close(file); Darwin.close(parent)
    }
    deinit { dispose() }
}

package struct DirectUpdateArchiveDownloader: Sendable {
    private let configuration: URLSessionConfiguration
    package init() {
        let value = SignedUpdateManifestFetcher.sessionConfiguration()
        value.timeoutIntervalForRequest = 30; value.timeoutIntervalForResource = 1800
        configuration = value
    }
    init(configuration: URLSessionConfiguration) { self.configuration = configuration.copy() as! URLSessionConfiguration }
    package func downloadInstalled(manifest: RetrievedUpdateManifest, app: URL) async throws -> DownloadedUpdateArchive {
        let policy = try DirectUpdateInstalledPolicy.inspect(installedApp: app)
        try policy.validate()
        let result = try await download(manifest: manifest, configuration: policy.metadata.configuration,
            installedVersion: policy.metadata.version, installedBuild: policy.metadata.build)
        do { try policy.validate(); return result } catch { result.dispose(); throw error }
    }
    package func download(manifest: RetrievedUpdateManifest, configuration trust: UpdateChannelConfiguration,
        installedVersion: String, installedBuild: Int,
        hostOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        clock: @Sendable () -> Date = { Date() },
        byteLimit: Int64 = DirectUpdateArchiveIntegrityService.maximumArchiveBytes) async throws -> DownloadedUpdateArchive {
        let verified = try DirectUpdateArchiveIntegrityService.admittedManifest(manifest.bytes, configuration: trust,
            installedVersion: installedVersion, installedBuild: installedBuild, hostOS: hostOS, now: clock())
        guard verified == manifest.verified, byteLimit > 0,
              byteLimit <= DirectUpdateArchiveIntegrityService.maximumArchiveBytes,
              let url = URL(string: verified.payload.downloadURL), Self.allowedInitialURL(url, name: verified.payload.archiveName)
        else { throw DirectUpdateDownloadError.response }
        let archive = try DownloadedUpdateArchive()
        do {
            let loader = ArchiveResponseLoader(url: url, expectedSHA256: verified.payload.sha256,
                configuration: configuration, archive: archive, limit: byteLimit)
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { loader.start($0) }
            } onCancel: { loader.cancel() }
            try Task.checkCancellation()
            guard try DirectUpdateArchiveIntegrityService.admittedManifest(manifest.bytes, configuration: trust,
                installedVersion: installedVersion, installedBuild: installedBuild, hostOS: hostOS, now: clock()) == verified
            else { throw DirectUpdateDownloadError.integrity }
            try archive.finish(); return archive
        } catch { archive.dispose(); throw error }
    }
    static func allowedInitialURL(_ url: URL, name: String) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), common(c), c.host == "github.com",
              c.query == nil, c.path.hasPrefix("/AffPapa/neantik/releases/download/"),
              !c.percentEncodedPath.contains("%"), !c.path.contains(".."), url.lastPathComponent == name
        else { return false }
        return c.path.split(separator: "/").count == 6
    }
    static func allowedRedirectURL(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), common(c) else { return false }
        return c.host == "release-assets.githubusercontent.com" && c.path.hasPrefix("/github-production-release-asset/")
    }
    private static func common(_ c: URLComponents) -> Bool {
        c.scheme == "https" && (c.port == nil || c.port == 443) && c.user == nil && c.password == nil && c.fragment == nil
    }
}

private final class ArchiveResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL, expectedSHA256: String, configuration: URLSessionConfiguration
    private let archive: DownloadedUpdateArchive, limit: Int64
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?, task: URLSessionDataTask?
    private var failure: Error?, cancelled = false, redirects = 0, received: Int64 = 0
    private var contentHasher = SHA256(), finalURL: URL
    init(url: URL, expectedSHA256: String, configuration: URLSessionConfiguration, archive: DownloadedUpdateArchive, limit: Int64) {
        self.url = url; self.finalURL = url; self.expectedSHA256 = expectedSHA256
        self.configuration = configuration; self.archive = archive; self.limit = limit
    }
    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        if cancelled { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue); self.session = session
        var request = URLRequest(url: url); request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request); self.task = task; task.resume()
    }
    func cancel() { lock.lock(); cancelled = true; failure = CancellationError(); let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let mime = response.mimeType?.lowercased()
        if (response as? HTTPURLResponse)?.statusCode != 200 || response.url != finalURL ||
            !["application/zip", "application/octet-stream", "application/x-zip-compressed"].contains(mime ?? "") {
            failure = failure ?? DirectUpdateDownloadError.response
        }
        if response.expectedContentLength > limit { failure = failure ?? DirectUpdateDownloadError.limit }
        let refused = failure != nil; lock.unlock(); completionHandler(refused ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if failure == nil {
            do {
                guard Int64(data.count) <= limit - received else { throw DirectUpdateDownloadError.limit }
                try archive.append(data, offset: received); received += Int64(data.count); contentHasher.update(data: data)
            } catch { failure = error }
        }
        let refused = failure != nil; lock.unlock(); if refused { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1
        if redirects > 3 || request.url.map(DirectUpdateArchiveDownloader.allowedRedirectURL) != true || request.httpMethod != "GET" {
            failure = failure ?? DirectUpdateDownloadError.redirect
        }
        if failure == nil { finalURL = request.url! }
        let refused = failure != nil; lock.unlock()
        // Do not forward arbitrary server-supplied headers or credentials.
        completionHandler(refused ? nil : URLRequest(url: request.url!))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { lock.lock(); failure = failure ?? DirectUpdateDownloadError.response; lock.unlock(); completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); failure = failure ?? error
        if failure == nil && (received == 0 || contentHasher.finalize().map({ String(format: "%02x", $0) }).joined() != expectedSHA256) { failure = DirectUpdateDownloadError.integrity }
        self.task = nil; lock.unlock(); session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock(); let continuation = continuation; self.continuation = nil; let failure = failure ?? error
        self.session = nil; self.task = nil; lock.unlock()
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume(returning: ()) }
    }
}
