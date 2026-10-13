import AppKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import NeAntik

@MainActor
@Suite(.serialized)
struct WebKitDownloadTests {
    @Test func stagedPublicationNeverOverwritesAndCleansOnlyOwnedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webkit-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("result.txt")
        let file = try WebKitDownloadFile(destination: target)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try Data("fixture".utf8).write(to: file.staging)
        try file.publish()
        #expect(try Data(contentsOf: target) == Data("fixture".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.directory.path))
        file.cleanup(); #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(throws: (any Error).self) { try WebKitDownloadFile(destination: target) }
        let raced = root.appendingPathComponent("collision.txt")
        let pending = try WebKitDownloadFile(destination: raced)
        try Data("download".utf8).write(to: pending.staging)
        try Data("existing".utf8).write(to: raced)
        #expect(throws: (any Error).self) { try pending.publish() }
        pending.cleanup()
        #expect(try Data(contentsOf: raced) == Data("existing".utf8))
        let bad = try WebKitDownloadFile(destination: root.appendingPathComponent("symlink-result"))
        try FileManager.default.createSymbolicLink(at: bad.staging, withDestinationURL: target)
        #expect(throws: (any Error).self) { try bad.publish() }
        bad.cleanup(); #expect(try Data(contentsOf: target) == Data("fixture".utf8))
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("absent"))
        #expect(throws: (any Error).self) { try WebKitDownloadFile(destination: dangling) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path).hasSuffix("absent"))
    }

    @Test func destinationDirectorySymlinkChangesCannotRedirectPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webkit-destination-" + UUID().uuidString)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let file = try WebKitDownloadFile(destination: alias.appendingPathComponent("result"))
        try Data("own".utf8).write(to: file.staging)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        try file.publish()
        #expect(try Data(contentsOf: first.appendingPathComponent("result")) == Data("own".utf8))
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("result").path))
        let changed = try WebKitDownloadFile(destination: first.appendingPathComponent("different"))
        try Data("own".utf8).write(to: changed.staging)
        try FileManager.default.moveItem(at: first, to: root.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try changed.publish() }
        changed.cleanup()
        #expect(!FileManager.default.fileExists(atPath: first.appendingPathComponent("different").path))
    }
    @Test func untrustedFilenameCannotSuggestTraversalOrControlCharacters() {
        #expect(WebKitDownloadFile.suggestedName("../../report.csv") == "report.csv")
        #expect(WebKitDownloadFile.suggestedName("C:\\fake\\report.csv") == "report.csv")
        #expect(WebKitDownloadFile.suggestedName("\u{0}..\n") == "download")
        #expect(WebKitDownloadFile.suggestedName(String(repeating: "x", count: 500)).count == 180)
    }

    @Test func reservationCapacityAndCloseWaitForUnconvertedPolicies() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let downloads = WebKitDownloads(window: window)
        let tokens = (0..<5).map { _ in NSObject() }
        for token in tokens.prefix(4) { #expect(downloads.reserve(token, from: view)) }
        #expect(downloads.activeCount == 4)
        #expect(!downloads.reserve(tokens[4], from: view))
        var drained = false
        downloads.close { drained = true }
        #expect(!drained && downloads.activeCount == 4)
        #expect(!drained, "A navigation failure or timeout cannot prove download settlement")
        #expect(!downloads.reserve(NSObject(), from: view))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_DOWNLOAD_LIVE"] == "1"))
    func headedDownloadsUseProfileCookiesAndCancelWithoutPublishingPartials() async throws {
        let ids = try await headedScenario()
        for id in [ids.0, ids.1] {
            try await Task.sleep(for: .milliseconds(200))
            let error: Error? = await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: id) { continuation.resume(returning: $0) }
            }
            #expect(error == nil, "Owned synthetic WebKit download store cleanup must succeed")
        }
    }
    private func headedScenario() async throws -> (UUID, UUID) {
        let raw = try #require(ProcessInfo.processInfo.environment["NEANTIK_WEBKIT_DOWNLOAD_FIXTURE"])
        let url = try #require(URL(string: raw))
        guard url.scheme == "http", url.host == "127.0.0.1", url.path == "/downloads-fixture",
              url.user == nil, url.password == nil else { throw NeAntikError.invalidProfile }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webkit-downloads-owned-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(rootDirectory: root.appendingPathComponent("metadata"))
        let a = BrowserProfile(name: "Owned download A", startURL: raw, engine: .webkit)
        let b = BrowserProfile(name: "Owned download B", startURL: raw, engine: .webkit)
        var selected: [URL] = []
        var cancelNextChoice = false
        let picker: WebKitDownloads.Picker = { _, reply in
            if cancelNextChoice { cancelNextChoice = false; reply(nil); return }
            let destination = root.appendingPathComponent("chosen-\(selected.count).txt")
            selected.append(destination); reply(destination)
        }
        var first: WebKitProfileBrowser? = try make(a, paths: paths, picker: picker)
        var second: WebKitProfileBrowser? = try make(b, paths: paths, picker: picker)
        defer { first?.close(); second?.close(); try? FileManager.default.removeItem(at: root) }
        first?.show(); second?.show()
        try await ready(try #require(first?.webView)); try await ready(try #require(second?.webView))
        let firstView = try #require(first?.webView), secondView = try #require(second?.webView)
        _ = try await firstView.evaluateJavaScript("document.cookie='download_fixture=A; Path=/; SameSite=Lax'")
        _ = try await secondView.evaluateJavaScript("document.cookie='download_fixture=B; Path=/; SameSite=Lax'")
        let firstDownloads = try #require(first?.downloads), secondDownloads = try #require(second?.downloads)
        _ = try await firstView.evaluateJavaScript("document.querySelector('#attribute').click()")
        try await wait { firstDownloads.snapshots.last?.state == .finished }
        #expect(try Data(contentsOf: selected[0]) == Data("owned-download-A".utf8))
        #expect(secondDownloads.snapshots.isEmpty)
        _ = try await secondView.evaluateJavaScript("document.querySelector('#attachment').click()")
        try await wait { secondDownloads.snapshots.last?.state == .finished }
        #expect(try Data(contentsOf: selected[1]) == Data("owned-download-B".utf8))
        _ = try await firstView.evaluateJavaScript("window.downloadBlob()")
        try await wait { firstDownloads.snapshots.count == 2 && firstDownloads.snapshots.last?.state == .finished }
        #expect(try Data(contentsOf: selected[2]) == Data("owned-blob".utf8))
        _ = try await firstView.evaluateJavaScript("document.querySelector('#slow').click()")
        try await wait { firstDownloads.snapshots.last?.state == .receiving && (firstDownloads.snapshots.last?.fraction ?? 0) > 0 }
        let cancelled = try #require(firstDownloads.snapshots.last)
        firstDownloads.cancel(cancelled.id)
        try await wait { firstDownloads.activeCount == 0 }
        #expect(firstDownloads.snapshots.last?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: selected[3].path))
        _ = try await firstView.evaluateJavaScript("document.querySelector('#slow').click()")
        try await wait { firstDownloads.activeCount == 1 && firstDownloads.snapshots.last?.state == .receiving }
        first?.close()
        if firstDownloads.activeCount > 0 {
            #expect(throws: ProfileProcessBusyError.self) { try paths.acquireWebKitSessionGuard(for: a.id) }
        }
        try await wait { firstDownloads.activeCount == 0 }
        #expect(!FileManager.default.fileExists(atPath: selected[4].path))
        let guardAfterDrain = try paths.acquireWebKitSessionGuard(for: a.id); guardAfterDrain.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".neantik-download-") }.isEmpty)
        _ = try await secondView.evaluateJavaScript("document.querySelector('#unknown').click()")
        try await wait { secondDownloads.snapshots.count == 2 && secondDownloads.snapshots.last?.state == .finished }
        #expect(try Data(contentsOf: selected[5]) == Data("owned-download-B".utf8))
        let beforeFailure = selected.count
        _ = try await secondView.evaluateJavaScript("document.querySelector('#truncated').click()")
        try await wait { secondDownloads.snapshots.count == 3 && secondDownloads.snapshots.last?.state == .failed }
        // A network failure may precede decideDestination. Either path must
        // leave no final file; do not assume the picker ran or index blindly.
        for destination in selected.dropFirst(beforeFailure) {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        cancelNextChoice = true
        _ = try await secondView.evaluateJavaScript("document.querySelector('#attachment').click()")
        try await wait { secondDownloads.snapshots.count == 4 && secondDownloads.snapshots.last?.state == .cancelled }
        #expect(!cancelNextChoice && selected.count >= beforeFailure)
        let beforeBoundary = selected.count
        var closedAtPolicyBoundary = false
        secondDownloads.onReservation = { [weak second] in
            closedAtPolicyBoundary = true; second?.close()
        }
        _ = try? await secondView.evaluateJavaScript("document.querySelector('#slow').click()")
        try await wait { closedAtPolicyBoundary && secondDownloads.activeCount == 0 }
        #expect(selected.count == beforeBoundary, "No destination is chosen after close inside policy conversion")
        secondDownloads.onReservation = nil
        second?.close(); first = nil; second = nil
        // Retained web views from this test are released when the function ends;
        // the separate native runner removes only its two synthetic stores.
        #expect(firstDownloads.activeCount == 0 && secondDownloads.activeCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".neantik-download-") }.isEmpty)
        return (a.id, b.id)
    }

    private func make(_ profile: BrowserProfile, paths: AppPaths, picker: @escaping WebKitDownloads.Picker) throws -> WebKitProfileBrowser {
        try WebKitProfileBrowser(profile: profile, lease: paths.acquireWebKitSessionGuard(for: profile.id),
                                 metadataLease: paths.acquireWebKitMetadataGuard(for: profile.id), downloadPicker: picker, onClose: {})
    }
    private func ready(_ view: WKWebView) async throws {
        try await wait { !view.isLoading }
        #expect(try await view.evaluateJavaScript("window.neantikDownloadFixture === true") as? Bool == true)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { throw WebKitProfileError.unsupported("Own download fixture timeout") }
    }
}
