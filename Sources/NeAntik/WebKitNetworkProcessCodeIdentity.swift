import CryptoKit
import CoreFoundation
import Darwin
import DirectUpdateCore
import Foundation

/// Pins and revalidates the exact owned WebKit Networking XPC process before
/// the broker can accept its PID as a profile-scoped network owner. Locator
/// data from host IPC is never treated as code identity.
enum WebKitNetworkProcessCodeIdentity {
    static let identifier = "app.neantik.desktop.webkit.Networking"
    static let pinKey = "NeAntikWebKitNetworkProcessV1"
    static let serviceRelativePath =
        "Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/Frameworks/WebKit.framework/Versions/A/XPCServices/" + identifier + ".xpc"

    enum Failure: Error, Equatable {
        case malformedPin
        case unsafeBundle
        case executableHashMismatch
        case codeIdentityMismatch
        case ownerChanged
    }

    struct Pin: Equatable, Sendable {
        let identifier: String
        let executable: String
        let sha256: String
        let cdHash: String

        init(propertyList value: Any?) throws {
            guard let object = value as? [String: Any],
                  Set(object.keys) == Set(["schemaVersion", "identifier", "executable", "sha256", "cdHash"]),
                  WebKitNetworkProcessCodeIdentity.isSchemaVersionOne(object["schemaVersion"]),
                  let identifier = object["identifier"] as? String,
                  identifier == Self.expectedIdentifier,
                  let executable = object["executable"] as? String,
                  executable.range(of: "^[A-Za-z0-9._-]{1,200}$", options: .regularExpression) != nil,
                  executable != ".", executable != "..",
                  let sha256 = object["sha256"] as? String,
                  sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let cdHash = object["cdHash"] as? String,
                  cdHash.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
            else { throw Failure.malformedPin }
            self.identifier = identifier
            self.executable = executable
            self.sha256 = sha256
            self.cdHash = cdHash
        }

        private static var expectedIdentifier: String { WebKitNetworkProcessCodeIdentity.identifier }

        var cdHashBytes: Data {
            Data(stride(from: 0, to: cdHash.count, by: 2).map { offset in
                let start = cdHash.index(cdHash.startIndex, offsetBy: offset)
                let end = cdHash.index(start, offsetBy: 2)
                return UInt8(cdHash[start..<end], radix: 16)!
            })
        }
    }

    /// A short-lived capability for one exact process generation. Call
    /// `revalidate` immediately before broker enrollment and before each lease
    /// renewal; the capability is not itself a profile/session authority.
    struct Attestation: @unchecked Sendable {
        fileprivate let owner: WebKitOwnedNetworkProcessPID.Owner
        fileprivate let code: ProxyRelayExpectedCode
    }

    /// Broker enrollment token bound to one immutable WebKit profile session.
    /// It must be revalidated before route registration, capability issuance,
    /// and accepting a new broker connection. It is not a durable lease.
    final class Lease: @unchecked Sendable {
        let session: WebKitHostIPC.Session
        private let attestation: Attestation?
        private let fixtureIsCurrent: (@Sendable () -> Bool)?

        fileprivate init(session: WebKitHostIPC.Session, attestation: Attestation?,
                         fixtureIsCurrent: (@Sendable () -> Bool)? = nil) {
            self.session = session
            self.attestation = attestation
            self.fixtureIsCurrent = fixtureIsCurrent
        }

        var scope: WebKitRelayAuthority.Scope {
            WebKitRelayAuthority.Scope(profileID: session.profileID,
                storeID: session.profileID, sessionID: session.generation,
                revision: session.revision)
        }

        func authorizes(_ scope: WebKitRelayAuthority.Scope) -> Bool {
            guard session.isValid(), scope.profileID == session.profileID,
                  scope.storeID == session.profileID, scope.sessionID == session.generation,
                  scope.revision == session.revision else { return false }
            if let attestation { return WebKitNetworkProcessCodeIdentity.revalidate(attestation) }
            #if DEBUG
            return fixtureIsCurrent?() == true
            #else
            return false
            #endif
        }

        #if DEBUG
        static func fixture(session: WebKitHostIPC.Session,
                            isCurrent: @escaping @Sendable () -> Bool) -> Lease {
            Lease(session: session, attestation: nil, fixtureIsCurrent: isCurrent)
        }
        #endif
    }

    static func pin(propertyList value: Any?) throws -> Pin { try Pin(propertyList: value) }

    static func executableURL(in managerBundle: URL, expectedExecutable: String) throws -> URL {
        guard expectedExecutable.range(of: "^[A-Za-z0-9._-]{1,200}$", options: .regularExpression) != nil,
              expectedExecutable != ".", expectedExecutable != "..",
              managerBundle.pathExtension == "app", managerBundle.isFileURL,
              isPhysicalDirectory(managerBundle),
              isPhysicalDirectory(managerBundle.appendingPathComponent("Contents", isDirectory: true)),
              isPhysicalFile(managerBundle.appendingPathComponent("Contents/Info.plist")),
              let managerInfo = NSDictionary(contentsOf: managerBundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              managerInfo["CFBundleIdentifier"] as? String == WebKitHostCodeIdentity.managerIdentifier
        else { throw Failure.unsafeBundle }
        var cursor = managerBundle
        for component in serviceRelativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: true)
            guard isPhysicalDirectory(cursor) else { throw Failure.unsafeBundle }
        }
        let service = managerBundle.appendingPathComponent(serviceRelativePath, isDirectory: true)
        let contents = service.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let infoURL = contents.appendingPathComponent("Info.plist")
        guard isPhysicalDirectory(service), isPhysicalDirectory(contents),
              isPhysicalDirectory(macOS), isPhysicalFile(infoURL),
              let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundleExecutable"] as? String == expectedExecutable,
              info["CFBundlePackageType"] as? String == "XPC!"
        else { throw Failure.unsafeBundle }
        let executable = macOS.appendingPathComponent(expectedExecutable)
        guard isPhysicalFile(executable), isMachO(executable) else { throw Failure.unsafeBundle }
        return executable
    }

    static func attest(owner: WebKitOwnedNetworkProcessPID.Owner,
                       managerBundle: URL = Bundle.main.bundleURL) throws -> Attestation {
        guard owner.pid > 1, owner.startedAtSeconds > 0,
              (0..<1_000_000).contains(owner.startedAtMicroseconds), owner.userID == geteuid(),
              matches(owner, snapshot: WebKitOwnedNetworkProcessPID.ProcessSnapshot.current(owner.pid))
        else { throw Failure.ownerChanged }
        let managerInfoURL = managerBundle.appendingPathComponent("Contents/Info.plist")
        guard isPhysicalFile(managerInfoURL),
              let managerInfo = NSDictionary(contentsOf: managerInfoURL) as? [String: Any],
              managerInfo["CFBundleIdentifier"] as? String == WebKitHostCodeIdentity.managerIdentifier
        else { throw Failure.unsafeBundle }
        let pin = try Pin(propertyList: managerInfo[pinKey])
        let executable = try executableURL(in: managerBundle, expectedExecutable: pin.executable)
        guard sha256(executable) == pin.sha256 else { throw Failure.executableHashMismatch }
        let service = managerBundle.appendingPathComponent(serviceRelativePath, isDirectory: true)
        let code: ProxyRelayExpectedCode
        do {
            code = try ProxyRelayExpectedCode.qualifiedPin(
                at: service, expectedIdentifier: pin.identifier,
                expectedTeamIdentifier: WebKitHostCodeIdentity.teamIdentifier,
                expectedCDHash: pin.cdHashBytes)
        } catch { throw Failure.codeIdentityMismatch }
        let attestation = Attestation(owner: owner, code: code)
        guard revalidate(attestation) else { throw Failure.codeIdentityMismatch }
        return attestation
    }

    static func lease(session: WebKitHostIPC.Session,
                      owner: WebKitOwnedNetworkProcessPID.Owner,
                      managerBundle: URL = Bundle.main.bundleURL) throws -> Lease {
        guard session.isValid(), session.profileID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw Failure.ownerChanged
        }
        return Lease(session: session,
                     attestation: try attest(owner: owner, managerBundle: managerBundle))
    }

    static func revalidate(_ attestation: Attestation) -> Bool {
        let owner = attestation.owner
        guard owner.userID == geteuid(),
              matches(owner, snapshot: WebKitOwnedNetworkProcessPID.ProcessSnapshot.current(owner.pid)),
              let process = ProxyRelaySocketOwnerInspector.processIdentity(owner.pid),
              process.userID == owner.userID,
              process.generation.startSeconds == owner.startedAtSeconds,
              process.generation.startMicroseconds == owner.startedAtMicroseconds,
              ProxyRelayLiveCodeVerifier.matches(processID: owner.pid,
                  expectedProcess: process, expectedCode: attestation.code),
              matches(owner, snapshot: WebKitOwnedNetworkProcessPID.ProcessSnapshot.current(owner.pid))
        else { return false }
        return true
    }

    static func matches(_ owner: WebKitOwnedNetworkProcessPID.Owner,
                        snapshot: WebKitOwnedNetworkProcessPID.ProcessSnapshot?) -> Bool {
        guard let snapshot, snapshot.isValid else { return false }
        return owner.pid == snapshot.pid &&
            owner.startedAtSeconds == snapshot.startedAtSeconds &&
            owner.startedAtMicroseconds == snapshot.startedAtMicroseconds &&
            owner.userID == snapshot.userID && owner.parentPID == snapshot.parentPID
    }

    private static func isSchemaVersionOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.intValue == 1 && number.doubleValue == 1
    }

    private static func isPhysicalDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isPhysicalFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xce, 0xfa, 0xed, 0xfe]),
                Data([0xfe, 0xed, 0xfa, 0xcf]), Data([0xfe, 0xed, 0xfa, 0xce]),
                Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
                Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca])].contains(magic)
    }

    private static func sha256(_ url: URL) -> String? {
        guard isPhysicalFile(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 1 << 20) else { break }
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            } catch { return nil }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
