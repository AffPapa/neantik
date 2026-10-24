import CryptoKit
import Darwin
import Foundation
import Testing
@testable import NeAntik

private let cPIDFunctionFixture: @convention(c) (UnsafeRawPointer?) -> Int32 = { store in
    store == nil ? 0 : 42137
}

struct WebKitOwnedNetworkProcessPIDTests {
    private func fixture() throws -> (URL, URL, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-owned-network-pid-" + UUID().uuidString,
                                    isDirectory: true)
        let app = root.appendingPathComponent("Host.app", isDirectory: true)
        let image = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("pinned owned WebKit fixture".utf8).write(to: image)
        let digest = SHA256.hash(data: try Data(contentsOf: image))
            .map { String(format: "%02x", $0) }.joined()
        return (root, app, digest)
    }

    private func attestedImage(app: URL, digest: String) throws
        -> WebKitRuntimeImageAttestation.VerifiedImage {
        let image = app.appendingPathComponent(
            "Contents/Frameworks/WebKit.framework/Versions/A/WebKit")
        return try WebKitRuntimeImageAttestation.attest(
            imagePaths: [image.path], bundleURL: app, expectedSHA256: digest)
    }

    @Test func resolvesPIDOnlyFromPinnedLoadedImageAndClosesHandle() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try attestedImage(app: app, digest: digest)
        let handle = UnsafeMutableRawPointer(bitPattern: 0x1200)!
        let symbol = UnsafeMutableRawPointer(bitPattern: 0x3400)!
        let store = UnsafeRawPointer(bitPattern: 0x5600)!
        var closed = false
        var invoked = false

        let pid = try WebKitOwnedNetworkProcessPID.resolve(
            storeAddress: store, verifiedImage: image,
            openImage: { path, flags in
                #expect(path == image.url.path)
                #expect(flags & Int32(RTLD_NOLOAD) != 0)
                return handle
            },
            lookupSymbol: { receivedHandle, name in
                #expect(receivedHandle == handle)
                #expect(name == "WKWebsiteDataStoreGetNetworkProcessIdentifier")
                return symbol
            },
            closeImage: { receivedHandle in
                #expect(receivedHandle == handle)
                closed = true
            },
            callFunction: { receivedSymbol, receivedStore in
                #expect(receivedSymbol == symbol)
                #expect(receivedStore == store)
                invoked = true
                return 32123
            },
            processIsLive: { $0 == 32123 })

        #expect(pid == 32123)
        #expect(invoked)
        #expect(closed)
    }

    @Test func invokesTheOwnedCFunctionWithItsExpectedPointerABI() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try attestedImage(app: app, digest: digest)
        let handle = UnsafeMutableRawPointer(bitPattern: 0x1200)!
        let store = UnsafeRawPointer(bitPattern: 0x5600)!
        let symbol = unsafeBitCast(cPIDFunctionFixture, to: UnsafeMutableRawPointer.self)

        let pid = try WebKitOwnedNetworkProcessPID.resolve(
            storeAddress: store, verifiedImage: image,
            openImage: { _, _ in handle },
            lookupSymbol: { _, _ in symbol },
            closeImage: { _ in },
            processIsLive: { $0 == 42137 })

        #expect(pid == 42137)
    }

    @Test func resolvesStableNetworkProcessSnapshotWhenXPCParentIsLaunchd() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try attestedImage(app: app, digest: digest)
        let handle = UnsafeMutableRawPointer(bitPattern: 0x1200)!
        let symbol = UnsafeMutableRawPointer(bitPattern: 0x3400)!
        let store = UnsafeRawPointer(bitPattern: 0x5600)!
        let snapshot = WebKitOwnedNetworkProcessPID.ProcessSnapshot(
            pid: 42137, startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 123_456, userID: 501, parentPID: 1)
        var reads = 0

        let owner = try WebKitOwnedNetworkProcessPID.resolveOwner(
            storeAddress: store, verifiedImage: image, expectedUserID: 501,
            openImage: { _, _ in handle }, lookupSymbol: { _, _ in symbol },
            closeImage: { _ in },
            callFunction: { _, _ in 42137 },
            readSnapshot: { pid in
                reads += 1
                return pid == 42137 ? snapshot : nil
            })

        #expect(owner.pid == 42137)
        #expect(owner.startedAtSeconds == snapshot.startedAtSeconds)
        #expect(owner.startedAtMicroseconds == snapshot.startedAtMicroseconds)
        #expect(owner.userID == 501)
        #expect(owner.parentPID == 1)
        #expect(reads == 2)
    }

    @Test func refusesWrongUserAndPidReuseDuringResolution() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try attestedImage(app: app, digest: digest)
        let handle = UnsafeMutableRawPointer(bitPattern: 0x1200)!
        let symbol = UnsafeMutableRawPointer(bitPattern: 0x3400)!
        let store = UnsafeRawPointer(bitPattern: 0x5600)!
        let first = WebKitOwnedNetworkProcessPID.ProcessSnapshot(
            pid: 42137, startedAtSeconds: 1_700_000_000,
            startedAtMicroseconds: 123_456, userID: 501, parentPID: 1)
        let reusedPID = WebKitOwnedNetworkProcessPID.ProcessSnapshot(
            pid: 42137, startedAtSeconds: 1_700_000_001,
            startedAtMicroseconds: 10, userID: 501, parentPID: 1)

        let cases: [(uid_t, WebKitOwnedNetworkProcessPID.ProcessSnapshot)] = [
            (uid_t(502), first),
            (uid_t(501), reusedPID)
        ]
        for (expectedUser, value) in cases {
            var readCount = 0
            #expect(throws: WebKitOwnedNetworkProcessPID.Failure.invalidProcessIdentity) {
                try WebKitOwnedNetworkProcessPID.resolveOwner(
                    storeAddress: store, verifiedImage: image, expectedUserID: expectedUser,
                    openImage: { _, _ in handle }, lookupSymbol: { _, _ in symbol },
                    closeImage: { _ in }, callFunction: { _, _ in 42137 },
                    readSnapshot: { _ in
                        readCount += 1
                        return readCount == 1 ? first : value
                    })
            }
        }
    }

    @Test func refusesToLoadAnImageThatDyldHasNotAlreadyLoaded() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try attestedImage(app: app, digest: digest)
        let store = UnsafeRawPointer(bitPattern: 0x5600)!
        var lookupCalled = false

        #expect(throws: WebKitOwnedNetworkProcessPID.Failure.imageNotLoaded) {
            try WebKitOwnedNetworkProcessPID.resolve(
                storeAddress: store, verifiedImage: image,
                openImage: { _, flags in
                    #expect(flags & Int32(RTLD_NOLOAD) != 0)
                    return nil
                },
                lookupSymbol: { _, _ in lookupCalled = true; return nil })
        }
        #expect(!lookupCalled)
    }

    @Test func closesImageAndRefusesMissingOwnedAPISymbol() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try attestedImage(app: app, digest: digest)
        let handle = UnsafeMutableRawPointer(bitPattern: 0x1200)!
        let store = UnsafeRawPointer(bitPattern: 0x5600)!
        var closed = false

        #expect(throws: WebKitOwnedNetworkProcessPID.Failure.symbolMissing) {
            try WebKitOwnedNetworkProcessPID.resolve(
                storeAddress: store, verifiedImage: image,
                openImage: { _, _ in handle },
                lookupSymbol: { _, _ in nil },
                closeImage: { _ in closed = true })
        }
        #expect(closed)
    }

    @Test func distinguishesStartingPIDFromDeadAndInvalidPIDs() throws {
        let (root, app, digest) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try attestedImage(app: app, digest: digest)
        let handle = UnsafeMutableRawPointer(bitPattern: 0x1200)!
        let symbol = UnsafeMutableRawPointer(bitPattern: 0x3400)!
        let store = UnsafeRawPointer(bitPattern: 0x5600)!

        for reportedPID: Int32 in [0, 1, -7, 32123] {
            let expected: WebKitOwnedNetworkProcessPID.Failure = reportedPID == 0
                ? .processStarting : .invalidProcessIdentifier
            #expect(throws: expected) {
                try WebKitOwnedNetworkProcessPID.resolve(
                    storeAddress: store, verifiedImage: image,
                    openImage: { _, _ in handle },
                    lookupSymbol: { _, _ in symbol },
                    closeImage: { _ in },
                    callFunction: { _, _ in reportedPID },
                    processIsLive: { _ in reportedPID != 32123 })
            }
        }
    }

    private var owner: WebKitOwnedNetworkProcessPID.Owner {
        .init(pid: 42137, startedAtSeconds: 1_700_000_000,
              startedAtMicroseconds: 123_456, userID: 501, parentPID: 1)
    }

    @MainActor @Test func waitsForLaunchCallbackWithoutBlockingMainActor() async throws {
        var launchCompleted = false
        var reads = 0
        var suspensions = 0
        let expected = owner
        let actual = try await WebKitOwnedNetworkProcessPID.waitForOwner(
            readOwner: {
                reads += 1
                guard launchCompleted else { throw WebKitOwnedNetworkProcessPID.Failure.processStarting }
                return expected
            },
            suspend: {
                suspensions += 1
                await Task { @MainActor in launchCompleted = true }.value
            })
        #expect(actual == expected)
        #expect(reads == 2)
        #expect(suspensions == 1)
    }

    @MainActor @Test func readyOwnerDoesNotWait() async throws {
        var suspensions = 0
        let expected = owner
        let actual = try await WebKitOwnedNetworkProcessPID.waitForOwner(
            readOwner: { expected }, suspend: { suspensions += 1 })
        #expect(actual == expected)
        #expect(suspensions == 0)
    }

    @MainActor @Test func zeroPIDHasBoundedDeadline() async {
        var time: TimeInterval = 0
        var reads = 0
        await #expect(throws: WebKitOwnedNetworkProcessPID.Failure.processStartupTimedOut) {
            try await WebKitOwnedNetworkProcessPID.waitForOwner(
                readOwner: {
                    reads += 1
                    throw WebKitOwnedNetworkProcessPID.Failure.processStarting
                }, now: { time }, suspend: { time += 1 })
        }
        #expect(reads == 3)
        #expect(time == 3)
    }

    @MainActor @Test func identityAndImageFailuresAreNeverRetried() async {
        let failures: [WebKitOwnedNetworkProcessPID.Failure] = [
            .imageNotLoaded, .symbolMissing, .invalidProcessIdentifier, .invalidProcessIdentity
        ]
        for failure in failures {
            var reads = 0
            var suspensions = 0
            await #expect(throws: failure) {
                try await WebKitOwnedNetworkProcessPID.waitForOwner(
                    readOwner: { reads += 1; throw failure },
                    suspend: { suspensions += 1 })
            }
            #expect(reads == 1)
            #expect(suspensions == 0)
        }
    }

    @MainActor @Test func cancellationStopsBeforeReadingOwner() async {
        var reads = 0
        let expected = owner
        let task = Task { @MainActor in
            try await WebKitOwnedNetworkProcessPID.waitForOwner(readOwner: {
                reads += 1
                return expected
            })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reads == 0)
    }

    @MainActor @Test func cancellationDuringWaitStopsRetrying() async {
        var reads = 0
        await #expect(throws: CancellationError.self) {
            try await WebKitOwnedNetworkProcessPID.waitForOwner(
                readOwner: {
                    reads += 1
                    throw WebKitOwnedNetworkProcessPID.Failure.processStarting
                }, suspend: { throw CancellationError() })
        }
        #expect(reads == 1)
    }
}
