import AppKit
import Darwin
import WebKit

/// WKDownload requires an absent destination. Stage beside the user-selected
/// file, then publish with exclusive rename: existing files are never overwritten.
final class WebKitDownloadFile {
    let destination: URL
    let directory: URL
    let staging: URL
    private let parent: URL
    private let parentFD: Int32
    private let stagingFD: Int32
    private var published = false

    init(destination: URL) throws {
        guard destination.isFileURL, destination.host == nil || destination.host == "localhost",
              !destination.lastPathComponent.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        self.destination = parent.appendingPathComponent(destination.lastPathComponent)
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var existing = stat()
        if fstatat(fd, self.destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            Darwin.close(fd); throw CocoaError(.fileWriteFileExists)
        }
        guard errno == ENOENT, Self.directoryMatches(fd, parent) else {
            Darwin.close(fd); throw CocoaError(.fileWriteUnknown)
        }
        let name = ".neantik-download-" + UUID().uuidString
        guard mkdirat(fd, name, 0o700) == 0 else { Darwin.close(fd); throw CocoaError(.fileWriteUnknown) }
        let stage = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { unlinkat(fd, name, AT_REMOVEDIR); Darwin.close(fd); throw CocoaError(.fileWriteUnknown) }
        let stageURL = parent.appendingPathComponent(name, isDirectory: true)
        guard Self.directoryMatches(fd, parent), Self.directoryMatches(stage, stageURL) else {
            unlinkat(fd, name, AT_REMOVEDIR); Darwin.close(stage); Darwin.close(fd)
            throw CocoaError(.fileWriteUnknown)
        }
        parentFD = fd; stagingFD = stage
        directory = stageURL; staging = directory.appendingPathComponent("payload")

    }
    deinit { Darwin.close(stagingFD); Darwin.close(parentFD) }

    private static func directoryMatches(_ fd: Int32, _ url: URL) -> Bool {
        var pinned = stat(), current = stat()
        return fstat(fd, &pinned) == 0 && lstat(url.path, &current) == 0 &&
            current.st_mode & S_IFMT == S_IFDIR && pinned.st_dev == current.st_dev && pinned.st_ino == current.st_ino
    }
    func publish() throws {
        guard !published else { return }
        var info = stat()
        guard Self.directoryMatches(parentFD, parent), fstatat(stagingFD, "payload", &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Same filesystem, exclusive rename preserves xattrs and also works
        // on writable volumes where hardlinks are unavailable.
        guard renameatx_np(stagingFD, "payload", parentFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw CocoaError(errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown)
        }
        published = true; cleanup()
    }
    /// Only after WebKit finish/failure/cancel completion. Directory fds ensure
    /// cleanup never follows a changed user symlink or deletes the destination.
    func cleanup() {
        unlinkat(stagingFD, "payload", 0)
        var pinned = stat(), current = stat()
        if fstat(stagingFD, &pinned) == 0,
           fstatat(parentFD, directory.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
           pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino {
            unlinkat(parentFD, directory.lastPathComponent, AT_REMOVEDIR)
        }
    }
    static func suggestedName(_ input: String) -> String {
        let name = input.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
        let cleaned = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." ? "download" : String(value.prefix(180))
    }
}

@MainActor
private final class WebKitDownloadRows: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
final class WebKitDownloads: NSObject, WKDownloadDelegate {
    enum State: Equatable { case choosing, receiving, cancelling, finished, cancelled, failed }
    struct Snapshot { let id: UUID; let state: State; let filename: String; let fraction: Double }
    typealias Picker = (String, @escaping @MainActor (URL?) -> Void) -> Void
    private final class Transfer {
        let id = UUID()
        var download: WKDownload?
        var state: State = .choosing
        var filename = "Файл"
        var file: WebKitDownloadFile?
        var savedDestination: URL?
        var fraction: Double = 0
        var completion: (@MainActor @Sendable (URL?) -> Void)?
        var observation: NSKeyValueObservation?
        var panel: NSSavePanel?
        init(_ download: WKDownload) { self.download = download }
        var active: Bool { [.choosing, .receiving, .cancelling].contains(state) }
    }
    private var transfers: [Transfer] = []
    // Policy conversion is asynchronous: count it before returning .download.
    private var reservations: [ObjectIdentifier: WKWebView] = [:]
    #if DEBUG
    // Test-only observation of the real policy→conversion boundary. No CLI,
    // environment variable or release authority can enable this hook.
    var onReservation: (() -> Void)?
    #endif
    private weak var window: NSWindow?
    private let picker: Picker?
    private var closing = false
    private var onDrained: (() -> Void)?
    private var progressRefresh: Task<Void, Never>?
    private let popover = NSPopover()
    private let rows = WebKitDownloadRows()
    let button = NSButton(title: "Загрузки", target: nil, action: nil)
    var activeCount: Int { transfers.filter(\.active).count + reservations.count }
    var snapshots: [Snapshot] {
        transfers.map { Snapshot(id: $0.id, state: $0.state, filename: $0.filename,
                                fraction: $0.download?.progress.fractionCompleted ?? $0.fraction) }
    }

    init(window: NSWindow, picker: Picker? = nil) {
        self.window = window; self.picker = picker
        super.init()
        button.target = self; button.action = #selector(showDownloads)
        button.bezelStyle = .rounded; button.toolTip = "Прогресс загрузок и отмена. Закрытие профиля отменяет незавершённые файлы."
        button.setAccessibilityLabel("Загрузки этого профиля")
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10
        rows.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        scroll.documentView = rows; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let controller = NSViewController(); controller.view = scroll
        popover.contentViewController = controller; popover.behavior = .transient
        refresh()
    }

    func reserve(_ token: AnyObject, from view: WKWebView) -> Bool {
        guard !closing, activeCount < 4, reservations[ObjectIdentifier(token)] == nil else { return false }
        reservations[ObjectIdentifier(token)] = view; refresh()
        return true
    }
    func policyAccepted() {
        #if DEBUG
        onReservation?()
        #endif
    }
    func hasReservations(for view: WKWebView) -> Bool { reservations.values.contains { $0 === view } }
    func adopt(_ download: WKDownload, token: AnyObject, allowed: Bool) {
        let reserved = reservations.removeValue(forKey: ObjectIdentifier(token)) != nil
        if transfers.contains(where: { $0.download === download }) { return }
        // Bounded in-memory history. Source URLs and resume data are not saved.
        while transfers.count >= 20, let index = transfers.firstIndex(where: { !$0.active }) {
            transfers.remove(at: index)
        }
        let transfer = Transfer(download); transfers.append(transfer)
        download.delegate = self
        if closing || !allowed || !reserved { cancel(transfer); return }
        transfer.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.scheduleProgressRefresh() }
        }
        refresh()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard !closing, let item = item(download), item.state == .choosing else { completionHandler(nil); return }
        item.filename = WebKitDownloadFile.suggestedName(suggestedFilename)
        item.completion = completionHandler
        let chosen: @MainActor (URL?) -> Void = { [weak self, weak item] url in
            guard let self, let item, let complete = item.completion else { return }
            item.completion = nil; item.panel = nil
            guard !self.closing, item.state == .choosing, let url else {
                complete(nil); self.cancel(item); return
            }
            do {
                let file = try WebKitDownloadFile(destination: url)
                item.filename = WebKitDownloadFile.suggestedName(file.destination.lastPathComponent)
                item.file = file; item.state = .receiving
                complete(file.staging)
            } catch {
                complete(nil); self.fail(item)
            }
            self.refresh()
        }
        if let picker { picker(item.filename, chosen) }
        else if let window, window.attachedSheet == nil {
            let panel = NSSavePanel(); item.panel = panel
            panel.title = "Сохранить загрузку"; panel.prompt = "Сохранить"
            panel.message = "Выбери новое имя файла. Существующие файлы не заменяются."
            panel.nameFieldStringValue = item.filename
            panel.beginSheetModal(for: window) { result in chosen(result == .OK ? panel.url : nil) }
        } else {
            chosen(nil) // No hidden queued modal sheets or automatic downloads.
        }
        refresh()
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(download), item.state == .receiving else { return }
        do {
            guard let file = item.file else { finish(item, .failed); return }
            try file.publish(); item.savedDestination = file.destination; finish(item, .finished)
        }
        catch { finish(item, .failed) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(download), item.state != .cancelling else { return }
        // NSError userInfo and resume data may contain authenticated URLs.
        // Keep only a human-readable category; never persist or log them.
        finish(item, (error as NSError).code == NSURLErrorCancelled ? .cancelled : .failed)
    }
    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        let permitted = request.url.map { url in
            WebKitProfilePolicy.permits(url) &&
                !(response.url?.scheme?.lowercased() == "https" && url.scheme?.lowercased() != "https")
        } == true
        decisionHandler(!closing && item(download)?.active == true && permitted ? .allow : .cancel)
    }

    func cancel(_ id: UUID) { if let item = transfers.first(where: { $0.id == id }) { cancel(item) } }
    private func cancel(_ item: Transfer, outcome: State = .cancelled) {
        guard item.active, item.state != .cancelling else { return }
        item.state = .cancelling
        let completion = item.completion; item.completion = nil; completion?(nil)
        if let panel = item.panel { window?.endSheet(panel, returnCode: .cancel); item.panel = nil }
        guard let download = item.download else { finish(item, outcome); return }
        download.cancel { [self, item] _ in finish(item, outcome) }
        refresh()
    }
    private func fail(_ item: Transfer) { cancel(item, outcome: .failed) }
    private func finish(_ item: Transfer, _ state: State) {
        guard item.active else { return }
        item.state = state
        let completion = item.completion; item.completion = nil; completion?(nil)
        if let panel = item.panel { window?.endSheet(panel, returnCode: .cancel); item.panel = nil }
        item.observation = nil
        item.fraction = item.download?.progress.fractionCompleted ?? item.fraction
        item.download?.delegate = nil; item.download = nil
        item.file?.cleanup(); item.file = nil
        refresh()
        notifyDrained()
    }
    private func notifyDrained() {
        if closing && activeCount == 0 { let callback = onDrained; onDrained = nil; callback?() }
    }
    /// Release the profile leases only after download cancellation has settled.
    /// A timeout cannot prove that the network producer has stopped.
    func close(onDrained: @escaping () -> Void) {
        guard !closing else { return }
        closing = true; progressRefresh?.cancel(); progressRefresh = nil
        popover.close(); self.onDrained = onDrained
        if activeCount == 0 { self.onDrained = nil; onDrained(); return }
        for item in transfers where item.active { cancel(item) }
    }
    private func item(_ download: WKDownload) -> Transfer? { transfers.first { $0.download === download } }
    private func scheduleProgressRefresh() {
        guard !closing, progressRefresh == nil else { return }
        progressRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.progressRefresh = nil; self.refresh()
        }
    }
    @objc private func showDownloads() {
        if popover.isShown { popover.close() }
        else { refresh(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY) }
    }
    @objc private func cancelButton(_ sender: NSButton) {
        if let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) { cancel(id) }
    }
    @objc private func revealButton(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UUID(uuidString: value),
              let item = transfers.first(where: { $0.id == id }), item.state == .finished,
              let destination = item.savedDestination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
    private func refresh() {
        button.title = activeCount == 0 ? "Загрузки" : "Загрузки · \(activeCount)"
        popover.contentSize = NSSize(width: 380, height: min(320, max(72, transfers.count * 70 + 24)))
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        if transfers.isEmpty { rows.addArrangedSubview(NSTextField(labelWithString: "Здесь появятся загрузки этого профиля.")); return }
        for item in transfers.reversed() {
            let name = NSTextField(labelWithString: item.filename); name.lineBreakMode = .byTruncatingMiddle
            name.font = .systemFont(ofSize: 14); name.widthAnchor.constraint(equalToConstant: 350).isActive = true
            let status: String
            switch item.state {
            case .choosing: status = "Выбери, куда сохранить файл"
            case .receiving: status = (item.download?.progress.totalUnitCount ?? 0) > 0 ? "Загрузка: \(Int(max(0, min(1, item.download?.progress.fractionCompleted ?? 0)) * 100))%" : "Файл загружается…"
            case .cancelling: status = "Отмена…"
            case .finished: status = "Сохранено"
            case .cancelled: status = "Отменено"
            case .failed: status = "Не удалось сохранить. Проверь сеть, место на диске и выбери новое имя."
            }
            let detail = NSTextField(wrappingLabelWithString: status); detail.font = .systemFont(ofSize: 12)
            let line = NSStackView(views: [detail]); line.orientation = .horizontal
            if item.active {
                let cancel = NSButton(title: "Отменить", target: self, action: #selector(cancelButton(_:)))
                cancel.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString); cancel.isEnabled = item.state != .cancelling
                line.addArrangedSubview(cancel)
            } else if item.state == .finished {
                let reveal = NSButton(title: "В Finder", target: self, action: #selector(revealButton(_:)))
                reveal.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
                line.addArrangedSubview(reveal)
            }
            let row = NSStackView(views: [name, line]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
            rows.addArrangedSubview(row)
        }
    }
}
