import CryptoKit
import Darwin
import Foundation

/// Code identity rules for the nested WebKit host. Bundle pins establish the
/// expected child; live SecCode checks bind that pin to the exact parent/child
/// PIDs. Static signature validity alone is never used as process identity.
enum WebKitHostCodeIdentity {
    static let managerIdentifier = "app.neantik.desktop"
    static let hostIdentifier = "app.neantik.desktop.webkit-host"
    private static let developmentManagerIdentifier = NeAntikApplicationEnvironment.developmentBundleIdentifier
    private static let developmentHostIdentifier = developmentManagerIdentifier + ".webkit-host"
    static let teamIdentifier = "H6VGU2M6JD"
    static let pinKey = "NeAntikWebKitHostV1"
    static let hostBundleRelativePath = "Contents/Helpers/webkit-v1/NeAntikWebKitHost.app"
    static let hostExecutableRelativePath =
        hostBundleRelativePath + "/Contents/MacOS/NeAntikWebKitHost"

    static func expectedHostIdentifier(for managerIdentifier: String?) -> String? {
        if managerIdentifier == Self.managerIdentifier { return Self.hostIdentifier }
        #if DEBUG
        if managerIdentifier == Self.developmentManagerIdentifier { return Self.developmentHostIdentifier }
        #endif
        return nil
    }

    static func isSupportedHostIdentifier(_ identifier: String?) -> Bool {
        if identifier == Self.hostIdentifier { return true }
        #if DEBUG
        if identifier == Self.developmentHostIdentifier { return true }
        #endif
        return false
    }

    private static func managerIdentifier(in managerBundle: URL) -> String? {
        let infoURL = managerBundle.appendingPathComponent("Contents/Info.plist")
        guard isPhysicalFile(infoURL),
              let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    /// Accept the release manager everywhere and the dedicated QA manager only
    /// in Debug builds. The child launch must pin the same identity that the
    /// bundle's signed Info.plist declares; otherwise an isolated development
    /// app is rejected before the helper can bootstrap.
    static func expectedManagerIdentifier(in managerBundle: URL) -> String? {
        guard let identifier = managerIdentifier(in: managerBundle) else {
            return nil
        }
        if identifier == Self.managerIdentifier { return identifier }
        #if DEBUG
        if identifier == Self.developmentManagerIdentifier { return identifier }
        #endif
        return nil
    }

    enum Failure: Error, Equatable {
        case malformedPin
        case unsafeBundle
        case hostHashMismatch
        case codeIdentityMismatch
        case parentIdentityMismatch
    }

    struct Pin: Equatable, Sendable {
        let identifier: String
        let sha256: String
        let cdHash: String

        init(propertyList value: Any?) throws {
            guard let object = value as? [String: Any],
                  Set(object.keys) == Set(["schemaVersion", "identifier", "sha256", "cdHash"]),
                  object["schemaVersion"] as? Int == 1,
                  let identifier = object["identifier"] as? String,
                  let sha256 = object["sha256"] as? String,
                  let cdHash = object["cdHash"] as? String,
                  WebKitHostCodeIdentity.isSupportedHostIdentifier(identifier),
                  sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  cdHash.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
            else { throw Failure.malformedPin }
            self.identifier = identifier
            self.sha256 = sha256
            self.cdHash = cdHash
        }

        var cdHashBytes: Data {
            Data(stride(from: 0, to: cdHash.count, by: 2).map { offset in
                let start = cdHash.index(cdHash.startIndex, offsetBy: offset)
                let end = cdHash.index(start, offsetBy: 2)
                return UInt8(cdHash[start..<end], radix: 16)!
            })
        }
    }

    static func helperURL(in managerBundle: URL) throws -> URL {
        guard managerBundle.pathExtension == "app", managerBundle.isFileURL,
              isPhysicalDirectory(managerBundle),
              isPhysicalDirectory(managerBundle.appendingPathComponent("Contents", isDirectory: true)),
              isPhysicalDirectory(managerBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)),
              isPhysicalDirectory(managerBundle.appendingPathComponent("Contents/Helpers/webkit-v1", isDirectory: true))
        else { throw Failure.unsafeBundle }
        let hostBundle = managerBundle.appendingPathComponent(hostBundleRelativePath, isDirectory: true)
        let hostContents = hostBundle.appendingPathComponent("Contents", isDirectory: true)
        let hostExecutable = managerBundle.appendingPathComponent(hostExecutableRelativePath)
        let infoURL = hostContents.appendingPathComponent("Info.plist")
        let expectedHost = expectedHostIdentifier(for: managerIdentifier(in: managerBundle))
        guard isPhysicalDirectory(hostBundle), isPhysicalDirectory(hostContents),
              isPhysicalDirectory(hostContents.appendingPathComponent("MacOS", isDirectory: true)),
              isPhysicalFile(infoURL), isPhysicalFile(hostExecutable),
              let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              info["CFBundleIdentifier"] as? String == expectedHost,
              info["CFBundleExecutable"] as? String == "NeAntikWebKitHost",
              info["CFBundlePackageType"] as? String == "APPL"
        else { throw Failure.unsafeBundle }
        let helper = hostExecutable
        guard helper.standardizedFileURL.path.hasSuffix("/" + hostExecutableRelativePath) else {
            throw Failure.unsafeBundle
        }
        return helper
    }

    static func pinnedHelperCode(in managerBundle: URL) throws -> (URL, ProxyRelayExpectedCode) {
        let helper = try helperURL(in: managerBundle)
        let infoURL = managerBundle.appendingPathComponent("Contents/Info.plist")
        guard isPhysicalFile(infoURL),
              let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
        else { throw Failure.unsafeBundle }
        let pin = try Pin(propertyList: info[pinKey])
        guard sha256(helper) == pin.sha256 else { throw Failure.hostHashMismatch }
        let code = try ProxyRelayExpectedCode.qualifiedPin(
            at: helper, expectedIdentifier: pin.identifier,
            expectedTeamIdentifier: teamIdentifier, expectedCDHash: pin.cdHashBytes)
        return (helper, code)
    }

    /// Runtime pin carried inside the signed helper bundle. The parent uses
    /// this exact digest in the session message; the child independently
    /// checks the same pin against dyld before reading profile data.
    static func pinnedRuntimeSHA256(in managerBundle: URL) throws -> String {
        _ = try pinnedHelperCode(in: managerBundle)
        let infoURL = managerBundle.appendingPathComponent(
            hostBundleRelativePath + "/Contents/Info.plist")
        guard isPhysicalFile(infoURL),
              let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
        else { throw Failure.unsafeBundle }
        do {
            return try WebKitRuntimeImageAttestation.Pin(
                propertyList: info[WebKitRuntimeImageAttestation.pinKey]).webKitSHA256
        } catch { throw Failure.unsafeBundle }
    }

    /// Child-side check. The child must be the exact pinned helper, and its
    /// direct parent must be the signed manager in the containing app bundle.
    static func verifyCurrentHostAndParent(executablePath: String,
                                           expectedParentPID: pid_t) throws {
        let helper = URL(fileURLWithPath: executablePath)
        guard helper.standardizedFileURL.path == executablePath,
              let managerBundle = managerBundle(for: helper),
              try helperURL(in: managerBundle) == helper,
              let (_, helperCode) = try? pinnedHelperCode(in: managerBundle),
              let childIdentity = ProxyRelaySocketOwnerInspector.processIdentity(getpid()),
              childIdentity.userID == geteuid(),
              childIdentity.parentProcessID == expectedParentPID,
              getppid() == expectedParentPID,
              ProxyRelayLiveCodeVerifier.matches(processID: getpid(),
                  expectedProcess: childIdentity, expectedCode: helperCode)
        else { throw Failure.codeIdentityMismatch }

        let managerExecutable = managerBundle.appendingPathComponent("Contents/MacOS/NeAntik")
        guard isPhysicalFile(managerExecutable),
              let parentIdentity = ProxyRelaySocketOwnerInspector.processIdentity(expectedParentPID),
              parentIdentity.userID == geteuid(),
              let managerCode = try? ProxyRelayExpectedCode.qualifiedPin(
                  at: managerExecutable,
                  expectedIdentifier: Self.managerIdentifier(in: managerBundle) ?? "",
                  expectedTeamIdentifier: teamIdentifier),
              ProxyRelayLiveCodeVerifier.matches(processID: expectedParentPID,
                  expectedProcess: parentIdentity, expectedCode: managerCode),
              ProxyRelaySocketOwnerInspector.processIdentity(expectedParentPID) == parentIdentity
        else { throw Failure.parentIdentityMismatch }
    }

    /// Parent-side check immediately after spawn and again before sending any
    /// session bootstrap bytes.
    static func verifyChild(processID: pid_t, expectedParentPID: pid_t,
                            managerBundle: URL) -> ProxyRelayOwnerProcessIdentity? {
        let managerExecutable = managerBundle.appendingPathComponent("Contents/MacOS/NeAntik")
        guard expectedParentPID == getpid(),
              managerBundle.pathExtension == "app",
              let currentExecutable = Bundle.main.executablePath,
              let currentBundle = NeAntikLaunchIntent.applicationBundleURL(
                forExecutablePath: currentExecutable),
              currentBundle.standardizedFileURL == managerBundle.standardizedFileURL,
              isPhysicalFile(managerExecutable),
              let managerCode = try? ProxyRelayExpectedCode.qualifiedPin(
                at: managerExecutable,
                expectedIdentifier: Self.managerIdentifier(in: managerBundle) ?? "",
                expectedTeamIdentifier: teamIdentifier),
              let parentBefore = ProxyRelaySocketOwnerInspector.processIdentity(getpid()),
              parentBefore.userID == geteuid(),
              ProxyRelayLiveCodeVerifier.matches(processID: getpid(),
                expectedProcess: parentBefore, expectedCode: managerCode),
              let (_, expectedCode) = try? pinnedHelperCode(in: managerBundle),
              let before = ProxyRelaySocketOwnerInspector.processIdentity(processID),
              before.userID == geteuid(), before.parentProcessID == getpid(),
              ProxyRelayLiveCodeVerifier.matches(processID: processID,
                  expectedProcess: before, expectedCode: expectedCode),
              ProxyRelaySocketOwnerInspector.processIdentity(processID) == before,
              ProxyRelayLiveCodeVerifier.matches(processID: getpid(),
                expectedProcess: parentBefore, expectedCode: managerCode),
              ProxyRelaySocketOwnerInspector.processIdentity(getpid()) == parentBefore else { return nil }
        return before
    }

    private static func managerBundle(for helper: URL) -> URL? {
        let suffix = "/" + hostExecutableRelativePath
        guard helper.standardizedFileURL.path.hasSuffix(suffix) else { return nil }
        let rootPath = String(helper.standardizedFileURL.path.dropLast(suffix.count))
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard root.pathExtension == "app",
              root.appendingPathComponent(hostExecutableRelativePath).standardizedFileURL == helper.standardizedFileURL
        else { return nil }
        return root
    }

    private static func isPhysicalDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isPhysicalFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func sha256(_ url: URL) -> String? {
        guard isPhysicalFile(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
