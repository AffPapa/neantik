import Foundation

package struct RetrievedUpdateManifest: Sendable {
    package let bytes: Data
    package let verified: VerifiedUpdateManifest
}

package enum UpdateManifestFetchError: Error, LocalizedError, Equatable {
    case response, tooLarge, authentication

    package var errorDescription: String? {
        switch self {
        case .response: "Сервер обновлений не вернул подписанный JSON. Повтори проверку позже."
        case .tooLarge: "Ответ сервера обновлений превышает допустимый размер."
        case .authentication: "Сервер обновлений запросил вход. Проверка остановлена."
        }
    }
}

/// Discovery returns a signed manifest, never installation authority. The owner
/// independently verifies these same bytes and the archive before its offer.
package struct SignedUpdateManifestFetcher: Sendable {
    package static let maximumBytes = 128 * 1024
    private let configuration: URLSessionConfiguration

    package init() { configuration = Self.sessionConfiguration() }
    init(configuration: URLSessionConfiguration) { self.configuration = configuration.copy() as! URLSessionConfiguration }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.httpCookieStorage = nil; value.httpShouldSetCookies = false
        value.urlCredentialStorage = nil; value.urlCache = nil
        value.requestCachePolicy = .reloadIgnoringLocalCacheData
        value.timeoutIntervalForRequest = 15; value.timeoutIntervalForResource = 20
        value.waitsForConnectivity = false
        return value
    }

    package func fetchInstalled(app: URL) async throws -> RetrievedUpdateManifest {
        let policy = try DirectUpdateInstalledPolicy.inspect(installedApp: app)
        try policy.validate()
        let result = try await fetch(configuration: policy.metadata.configuration,
            installedVersion: policy.metadata.version, installedBuild: policy.metadata.build)
        try policy.validate()
        try Task.checkCancellation()
        // The policy inspection can outlive the manifest's validity window.
        _ = try UpdateManifestVerifier.verify(result.bytes, configuration: policy.metadata.configuration,
            installedVersion: policy.metadata.version, installedBuild: policy.metadata.build, now: Date())
        return result
    }

    package func fetch(configuration trust: UpdateChannelConfiguration,
                       installedVersion: String, installedBuild: Int,
                       hostOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                       now: @Sendable () -> Date = { Date() }) async throws -> RetrievedUpdateManifest {
        guard trust.isEnabled, let url = trust.manifestURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.port == nil || components.port == 443,
              ["browser.free", "github.com"].contains(components.host?.lowercased() ?? ""),
              let key = trust.publicKey, let keyID = trust.publicKeyID,
              UpdateChannelConfiguration.fromInfoDictionary([
                UpdateChannelConfiguration.enabledKey: true,
                UpdateChannelConfiguration.manifestURLKey: url.absoluteString,
                UpdateChannelConfiguration.publicKeyIDKey: keyID,
                UpdateChannelConfiguration.publicKeyKey: key.base64EncodedString()
              ]) == trust else { throw UpdateManifestError.channelDisabled }
        let loader = ManifestResponseLoader(url: url, configuration: configuration)
        let bytes = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { loader.start($0) }
        } onCancel: { loader.cancel() }
        try Task.checkCancellation()
        let verified = try UpdateManifestVerifier.verify(bytes, configuration: trust,
            installedVersion: installedVersion, installedBuild: installedBuild, now: now())
        if verified.isNewerThanInstalled {
            _ = try DirectUpdateArchiveIntegrityService.admittedManifest(bytes, configuration: trust,
                installedVersion: installedVersion, installedBuild: installedBuild, hostOS: hostOS, now: now())
        }
        try Task.checkCancellation()
        return .init(bytes: bytes, verified: verified)
    }
}

/// Delegate callbacks use one serial queue; cancellation may arrive anywhere.
/// Cancellation/refusal resumes only after URLSession confirms task completion,
/// so the caller's operation fence never outlives an active transfer unnoticed.
private final class ManifestResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL, configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?, task: URLSessionDataTask?
    private var bytes = Data(), failure: Error?, cancelled = false

    init(url: URL, configuration: URLSessionConfiguration) { self.url = url; self.configuration = configuration }

    func start(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request); self.task = task
        task.resume(); lock.unlock()
    }
    func cancel() {
        lock.lock(); cancelled = true; failure = CancellationError(); let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let mime = response.mimeType?.lowercased() ?? ""
        let allowed = (response as? HTTPURLResponse)?.statusCode == 200 && response.url == url &&
            (mime == "application/json" || (mime.hasPrefix("application/") && mime.hasSuffix("+json")))
        lock.lock()
        if !allowed { failure = failure ?? UpdateManifestFetchError.response }
        if response.expectedContentLength > SignedUpdateManifestFetcher.maximumBytes {
            failure = failure ?? UpdateManifestFetchError.tooLarge
        }
        let rejected = failure != nil; lock.unlock()
        completionHandler(rejected ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if failure == nil {
            if data.count > SignedUpdateManifestFetcher.maximumBytes - bytes.count { failure = UpdateManifestFetchError.tooLarge }
            else { bytes.append(data) }
        }
        let rejected = failure != nil; lock.unlock()
        if rejected { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A pinned manifest URL must serve its JSON directly. Never carry this
        // request to login, another origin or a credential-bearing redirect.
        lock.lock(); failure = failure ?? UpdateManifestFetchError.response; lock.unlock()
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            lock.lock(); failure = failure ?? UpdateManifestFetchError.authentication; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let failure = failure ?? error, bytes = bytes
        self.session = nil; self.task = nil; self.bytes = Data()
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure { continuation?.resume(throwing: failure) }
        else { continuation?.resume(returning: bytes) }
    }
}
