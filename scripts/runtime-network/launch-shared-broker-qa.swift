import AppKit
import Foundation
import CryptoKit
import Darwin

/// Exact-hash, exact-root launcher for the one approved 0a78 shared-broker QA.
/// `--check-only` is inert. `--launch` reads fresh kernel/thermal admission
/// through the hash-pinned project helper immediately before Launch Services;
/// it never launches a production bundle or profile root.
@main struct SharedBrokerQALauncher {
    static let appPath = "/private/tmp/neantik-webkit-shared-broker-pool-fresh-extract-20261021/NeAntik.app"
    static let archivePath = "/private/tmp/neantik-webkit-shared-broker-pool-qacandidate-20261021-01/NeAntik-WebKit-SharedBroker-Pool-QA-20261021.zip"
    static let dataRoot = "/private/tmp/neantik-webkit-shared-broker-pool-qa-root-20261021"
    static let profilesPath = dataRoot + "/profiles.json"
    static let readinessHelper = "/Users/dumay/rumors-wtf/neantik-open-source/scripts/native-qa-readiness.py"
    static let archiveSHA256 = "0a78e1a80cdca443699859104ab36e272f25fa7ceeea7e88d702d563d0f596d9"
    static let profilesSHA256 = "b33dff8fc1177ab273c759e34d3d2eac0f7191ce4d206bedc930e6a70e553c3a"
    static let managerSHA256 = "ff99812b38b4333949963bdcb7a1631a7f72900f181ce0a90b6a36defd1d426a"
    static let hostSHA256 = "0fe13bc2a06a429e5c790e22bd609f2c1a8c13cc09a62bcdd708e8e2395083bb"
    static let readinessHelperSHA256 = "459f828447166af3ee80e1d117582aeb5a45e5d8ff3c54ee0464a6fe8fdb8f5d"
    static let prefix = "Shared Broker QA 20261021"

    static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data(("REFUSED: " + reason + "\n").utf8))
        exit(1)
    }

    static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func command(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func validatePhysicalEntry(_ path: String, type expectedType: mode_t,
                                      permissions expectedPermissions: mode_t) throws {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        guard result == 0,
              (info.st_mode & mode_t(S_IFMT)) == expectedType,
              info.st_uid == getuid(),
              (info.st_mode & mode_t(0o7777)) == expectedPermissions else {
            fail("QA path must be an owner-only physical file or directory")
        }
    }

    static func validateProfiles() throws {
        let root = URL(fileURLWithPath: dataRoot, isDirectory: true)
        // macOS resolves the /private/tmp alias to /tmp. Pin the resolved
        // location, not its spelling, and never accept an arbitrary root.
        let canonicalRoot = "/tmp/neantik-webkit-shared-broker-pool-qa-root-20261021"
        guard root.resolvingSymlinksInPath().path == canonicalRoot else { fail("profile root symlink/path mismatch") }
        try validatePhysicalEntry(dataRoot, type: mode_t(S_IFDIR), permissions: 0o700)
        try validatePhysicalEntry(profilesPath, type: mode_t(S_IFREG), permissions: 0o600)
        guard try sha256(URL(fileURLWithPath: profilesPath)) == profilesSHA256 else { fail("profile store SHA-256 mismatch") }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: profilesPath)),
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["schemaVersion"] as? Int == 5,
              let profiles = document["profiles"] as? [[String: Any]], profiles.count == 2 else {
            fail("profile store schema mismatch")
        }
        let a = profiles.first { $0["name"] as? String == prefix + " A proxy" }
        let b = profiles.first { $0["name"] as? String == prefix + " B direct" }
        guard let a, let b,
              a["id"] as? String != b["id"] as? String,
              a["engine"] as? String == "webkit", b["engine"] as? String == "webkit",
              a["webKitRuntimeGeneration"] as? String == "isolatedV1",
              b["webKitRuntimeGeneration"] as? String == "isolatedV1",
              a["startURL"] as? String == "http://127.0.0.1:45102/proxy-a",
              b["startURL"] as? String == "http://127.0.0.1:45102/direct-b",
              let proxy = a["proxy"] as? [String: Any],
              proxy["kind"] as? String == "http", proxy["host"] as? String == "127.0.0.1",
              proxy["port"] as? Int == 45101, proxy["username"] as? String == "",
              b["proxy"] is NSNull else {
            fail("A/B route configuration is not the approved loopback fixture")
        }
    }

    /// Persist a minimal, secret-free admission receipt before deciding whether
    /// Launch Services may be called. The readiness helper itself emits only
    /// aggregate pressure/thermal fields and categorical observer failures.
    static func persistAdmissionReceipt(_ receipt: [String: Any], helperStatus: Int32,
                                        ageSeconds: Int) throws {
        guard let observedAt = receipt["observedAt"] as? String else {
            fail("native-QA readiness timestamp is missing")
        }
        let stamp = String(observedAt.filter {
            $0.isNumber || $0 == "T" || $0 == "Z"
        })
        guard stamp.count >= 16 else { fail("native-QA receipt filename timestamp is invalid") }
        let evidenceDirectory = URL(fileURLWithPath:
            "/Users/dumay/rumors-wtf/neantik-open-source/docs/evidence",
            isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: evidenceDirectory.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else {
            fail("native-QA evidence directory is missing")
        }
        let destination = evidenceDirectory.appendingPathComponent(
            "native-qa-admission-\(stamp)-shared-broker.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            fail("native-QA admission receipt already exists; refusing overwrite")
        }
        let allowedKeys = [
            "schemaVersion", "status", "observedAt", "eligibleForAttempt",
            "memoryPressure", "thermalState", "reasons", "observerFailures",
            "releaseQualified", "boundary",
        ]
        var redacted: [String: Any] = [
            "candidateSHA256": archiveSHA256,
            "helperExitStatus": helperStatus,
            "helperAgeSeconds": ageSeconds,
            "scope": "aggregate native-QA admission only; exact Dev QA candidate 0a78",
        ]
        for key in allowedKeys {
            if let value = receipt[key] { redacted[key] = value }
        }
        let data = try JSONSerialization.data(withJSONObject: redacted,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
        print("ADMISSION_RECEIPT \(destination.path)")
    }

    static func validateBundle() throws -> URL {
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        let archive = URL(fileURLWithPath: archivePath)
        guard try sha256(archive) == archiveSHA256,
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "app.neantik.desktop.dev",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.8.26",
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "138",
              Bundle(url: app)?.executableURL?.resolvingSymlinksInPath().path ==
                URL(fileURLWithPath: appPath + "/Contents/MacOS/NeAntik").resolvingSymlinksInPath().path,
              try sha256(URL(fileURLWithPath: appPath + "/Contents/MacOS/NeAntik")) == managerSHA256,
              try sha256(URL(fileURLWithPath: appPath + "/Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents/MacOS/NeAntikWebKitHost")) == hostSHA256 else {
            fail("archive, bundle identity, manager or WebKit host does not match 0a78")
        }
        let (verifyStatus, _) = try command("/usr/bin/codesign", [
            "--verify", "--deep", "--strict", "--verbose=2", appPath,
        ])
        guard verifyStatus == 0 else { fail("full extracted app signature verification failed") }
        let (detailStatus, details) = try command("/usr/bin/codesign", [
            "-dv", "--verbose=4", appPath,
        ])
        guard detailStatus == 0,
              details.contains("Identifier=app.neantik.desktop.dev"),
              details.contains("TeamIdentifier=H6VGU2M6JD") else {
            fail("full extracted app signing identity does not match the approved Dev candidate")
        }
        return app
    }

    static func validateCurrentAdmission() throws {
        let helper = URL(fileURLWithPath: readinessHelper)
        guard try sha256(helper) == readinessHelperSHA256 else {
            fail("trusted native-QA readiness helper hash mismatch")
        }
        let (status, output) = try command("/usr/bin/python3", [readinessHelper, "--check"])
        guard let data = output.data(using: .utf8),
              let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail("fresh native-QA readiness output is not valid JSON")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let rawObservedAt = receipt["observedAt"] as? String,
              let observedAt = formatter.date(from: rawObservedAt) else {
            fail("native-QA readiness timestamp is invalid")
        }
        let age = Date().timeIntervalSince(observedAt)
        try persistAdmissionReceipt(receipt, helperStatus: status,
                                    ageSeconds: Int(age.rounded(.down)))
        guard (0...30).contains(age) else { fail("native-QA readiness observation is not fresh") }
        let pressure = receipt["memoryPressure"] as? Int
        let thermal = receipt["thermalState"] as? Int
        let eligible = receipt["eligibleForAttempt"] as? Bool == true
        let reasons = (receipt["reasons"] as? [String] ?? []).joined(separator: ",")
        print("ADMISSION eligible=\(eligible) pressure=\(pressure.map(String.init) ?? "unknown") thermal=\(thermal.map(String.init) ?? "unknown") reasons=\(reasons)")
        guard status == 0 else { fail("fresh native-QA readiness denied launch") }
        guard receipt["status"] as? String == "not-run",
              (receipt["reasons"] as? [String])?.isEmpty == true,
              eligible,
              pressure == 1,
              let thermal, thermal < 2,
              receipt["releaseQualified"] as? Bool == false else {
            fail("fresh native-QA readiness conditions are not eligible")
        }
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                fail("usage: --check-only | --launch")
            }
            let app = try validateBundle()
            try validateProfiles()
            let existing = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == "app.neantik.desktop.dev"
            }
            guard existing.isEmpty else { fail("another Dev app is running; refusing ambiguous owner") }
            if CommandLine.arguments[1] == "--check-only", CommandLine.arguments.count == 2 {
                print("PASS exact archive/app pins, manager+host hashes, owner-only A/B isolatedV1 fixture; no app launch")
                return
            }
            guard CommandLine.arguments[1] == "--launch", CommandLine.arguments.count == 2 else {
                fail("invalid invocation")
            }
            try validateCurrentAdmission()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.allowsRunningApplicationSubstitution = false
            configuration.environment = ["NEANTIK_DEVELOPMENT_DATA_ROOT": dataRoot]
            let running = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            let expectedBundlePath = URL(fileURLWithPath: appPath, isDirectory: true)
                .resolvingSymlinksInPath().path
            guard running.bundleIdentifier == "app.neantik.desktop.dev",
                  running.bundleURL?.resolvingSymlinksInPath().path == expectedBundlePath else {
                fail("Launch Services returned a different app")
            }
            print("LAUNCHED pid=\(running.processIdentifier) exactBundle=0a78 dataRoot=isolatedV1-qa")
        } catch {
            fail("preflight failed: \(error.localizedDescription)")
        }
    }
}
