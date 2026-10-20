import CryptoKit
import Foundation
import Testing
@testable import NeAntik

struct WebKitRuntimeImageAttestationTests {
    private func fixture() throws -> (URL, URL, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-webkit-image-" + UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Host.app", isDirectory: true)
        let image = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("owned webkit fixture".utf8).write(to: image)
        let digest = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }.joined()
        return (root, app, digest)
    }

    @Test func acceptsOnlyThePinnedFrameworkLoadedFromThisHostBundle() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")

        #expect(try WebKitRuntimeImageAttestation.verify(
            imagePaths: [expected.path], bundleURL: app, expectedSHA256: digest) == expected)
    }

    @Test func rejectsTheSameNamedSystemFramework() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: WebKitRuntimeImageAttestation.Failure.wrongRuntimeImage) {
            try WebKitRuntimeImageAttestation.verify(
                imagePaths: ["/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"],
                bundleURL: app, expectedSHA256: digest)
        }
    }

    @Test func refusesMissingOrDuplicateFrameworkImages() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")

        #expect(throws: WebKitRuntimeImageAttestation.Failure.missingRuntimeImage) {
            try WebKitRuntimeImageAttestation.verify(imagePaths: [], bundleURL: app,
                                                     expectedSHA256: digest)
        }
        #expect(throws: WebKitRuntimeImageAttestation.Failure.ambiguousRuntimeImage) {
            try WebKitRuntimeImageAttestation.verify(
                imagePaths: [expected.path,
                    "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"],
                bundleURL: app, expectedSHA256: digest)
        }
    }

    @Test func rejectsChangedBinaryAndMalformedPin() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")

        #expect(throws: WebKitRuntimeImageAttestation.Failure.runtimeHashMismatch) {
            try WebKitRuntimeImageAttestation.verify(imagePaths: [expected.path], bundleURL: app,
                                                     expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(throws: WebKitRuntimeImageAttestation.Failure.malformedPin) {
            try WebKitRuntimeImageAttestation.Pin(propertyList: [
                "schemaVersion": 1, "webKitSHA256": digest, "extra": "not allowed"
            ])
        }
    }

    @Test func rejectsFrameworkBundleSymlinks() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let framework = frameworks.appendingPathComponent("WebKit.framework", isDirectory: true)
        let outside = root.appendingPathComponent("outside.framework", isDirectory: true)
        try FileManager.default.moveItem(at: framework, to: outside)
        try FileManager.default.createSymbolicLink(at: framework, withDestinationURL: outside)

        #expect(throws: WebKitRuntimeImageAttestation.Failure.unsafeBundle) {
            try WebKitRuntimeImageAttestation.verify(imagePaths: [], bundleURL: app,
                                                     expectedSHA256: digest)
        }
    }
}
