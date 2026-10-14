import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

struct FingerprintEvidenceRetirementTests {
    @Test func frameworkLinksDoNotSkipVersionedHelpers() throws {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-retirement-framework-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: root) }
        let dirs = [".", "Framework", "Framework/Versions", "Framework/Versions/156.0.8078.12",
                    "Framework/Versions/156.0.8078.12/Helpers", "Framework/Versions/156.0.8078.12/Helpers/Helper.app",
                    "Framework/Versions/156.0.8078.12/Helpers/Helper.app/Contents",
                    "Framework/Versions/156.0.8078.12/Helpers/Helper.app/Contents/MacOS",
                    "Framework/Versions/156.0.8078.12/Resources"]
        let files = ["Framework/Versions/156.0.8078.12/Framework",
                     "Framework/Versions/156.0.8078.12/Helpers/Helper.app/Contents/MacOS/Helper",
                     "Framework/Versions/156.0.8078.12/Resources/owned.txt"]
        let links = [("Framework/Framework", "Versions/Current/Framework"),
                     ("Framework/Helpers", "Versions/Current/Helpers"),
                     ("Framework/Resources", "Versions/Current/Resources"),
                     ("Framework/Versions/Current", "156.0.8078.12")]
        var rows = [[String: Any]]()
        for dir in dirs {
            let url = dir == "." ? root : root.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #expect(chmod(url.path, 0o700) == 0)
            rows.append(["bundlePath": dir, "kind": "directory", "mode": 0o700])
        }
        let bytes = Data("own".utf8), hash = SHA256.hash(data: Data("own".utf8)).map { String(format: "%02x", $0) }.joined()
        for file in files {
            let url = root.appendingPathComponent(file); try bytes.write(to: url); #expect(chmod(url.path, 0o600) == 0)
            rows.append(["bundlePath": file, "kind": "file", "mode": 0o600, "size": 3, "sha256": hash])
        }
        for (link, target) in links {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(link).path, withDestinationPath: target)
            rows.append(["bundlePath": link, "kind": "symlink", "target": target])
        }
        rows.sort { ($0["bundlePath"] as! String) < ($1["bundlePath"] as! String) }
        let manifest = try JSONSerialization.data(withJSONObject: ["bundleInventory": rows, "postPreparationMutablePaths": ["Contents/CodeResources"]])
        try FingerprintEvidenceRetirement.validateInventory(app: root, manifest: manifest)
    }
    @Test(arguments: ["valid", "changed-file", "extra", "missing", "changed-mode", "foreign-link", "fifo", "mutable-policy"])
    func candidateInventoryRejectsEveryChangedSurface(control: String) throws {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-retirement-unit-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let body = root.appendingPathComponent("body"), empty = root.appendingPathComponent("empty")
        try Data("owned".utf8).write(to: body); try Data().write(to: empty)
        #expect(chmod(body.path, 0o600) == 0 && chmod(empty.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "body")
        let rows: [[String: Any]] = [
            ["bundlePath": ".", "kind": "directory", "mode": 0o700],
            ["bundlePath": "body", "kind": "file", "mode": 0o600, "size": 5,
             "sha256": SHA256.hash(data: Data("owned".utf8)).map { String(format: "%02x", $0) }.joined()],
            ["bundlePath": "empty", "kind": "file", "mode": 0o600, "size": 0,
             "sha256": SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()],
            ["bundlePath": "link", "kind": "symlink", "target": "body"]
        ]
        switch control {
        case "changed-file": try Data("other".utf8).write(to: body)
        case "extra": try Data("extra".utf8).write(to: root.appendingPathComponent("extra"))
        case "missing": try FileManager.default.removeItem(at: empty)
        case "changed-mode": #expect(chmod(body.path, 0o644) == 0)
        case "foreign-link":
            let link = root.appendingPathComponent("link")
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        case "fifo": #expect(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
        default: break
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["bundleInventory": rows,
            "postPreparationMutablePaths": control == "mutable-policy" ? ["body"] : ["Contents/CodeResources"]])
        if control == "valid" {
            try FingerprintEvidenceRetirement.validateInventory(app: root, manifest: manifest)
        } else {
            #expect(throws: (any Error).self) { try FingerprintEvidenceRetirement.validateInventory(app: root, manifest: manifest) }
        }
    }

    @Test func ordinaryMissingCandidateFailsBeforeAnyAuthorityOrOutput() throws {
        let root = URL(fileURLWithPath: "/private/tmp/neantik-retirement-unit-" + UUID().uuidString.lowercased())
        let request = FingerprintEvidenceRetirementRequest(candidateAppURL: root.appendingPathComponent("NeAntik.app"),
            candidateManifestURL: root.appendingPathComponent("manifest.json"), outputURL: root.appendingPathComponent("fingerprint-retirement.json"))
        #expect(throws: (any Error).self) { try FingerprintEvidenceRetirement.run(request) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
