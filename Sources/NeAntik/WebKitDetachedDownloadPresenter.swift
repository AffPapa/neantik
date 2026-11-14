#if NEANTIK_WEBKIT_PROXY_PRODUCTION
import AppKit
import Darwin
import Foundation

@MainActor
final class WebKitDetachedDownloadPresenter {
    private final class Transfer {
        let socket: FileHandle
        var panel: NSSavePanel?
        var file: WebKitDownloadFile?
        var task: Task<Void, Never>?
        var copying: Task<Void, any Error>?
        var waitingForChoice: Task<Void, Never>?
        let filename: String

        init(socket: FileHandle, filename: String) {
            self.socket = socket
            self.filename = filename
        }
    }

    private let intake: FileHandle
    private let generation: UUID
    private weak var window: NSWindow?
    private var listening: Task<Void, Never>?
    private var active: [UUID: Transfer] = [:]
    private var queued: [UUID] = []
    private var onStatus: ((String) -> Void)?
    private var onFailure: (() -> Void)?
    var hasActiveTransfers: Bool { !active.isEmpty }

    init(intake: FileHandle, generation: UUID, window: NSWindow,
         onStatus: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
        self.intake = intake
        self.generation = generation
        self.window = window
        self.onStatus = onStatus
        self.onFailure = onFailure
    }

    func start() {
        let intake = intake
        let generation = generation
        listening = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let (offer, socket) = try WebKitDownloadChannel.accept(on: intake, generation: generation, timeout: 2)
                    await self?.enqueue(offer, socket: socket)
                } catch ProxyRelayPrivatePipe.Failure.timeout {
                    continue
                } catch {
                    if !Task.isCancelled { await self?.fail() }
                    return
                }
            }
        }
    }

    private func fail() { onFailure?() }

    private func enqueue(_ offer: WebKitDownloadChannel.Offer, socket: FileHandle) {
        guard listening != nil else { WebKitDownloadChannel.stop(socket); return }
        guard active.count < 4, active[offer.id] == nil else {
            WebKitDownloadChannel.stop(socket)
            onFailure?()
            return
        }
        let transfer = Transfer(socket: socket, filename: offer.filename)
        active[offer.id] = transfer
        transfer.waitingForChoice = Task.detached { [weak self] in
            WebKitDownloadChannel.waitForPeerClose(socket)
            if !Task.isCancelled { await self?.choiceLost(offer.id) }
        }
        queued.append(offer.id)
        onStatus?("Выбери, куда сохранить файл")
        showNext()
    }

    private func choiceLost(_ id: UUID) {
        guard let transfer = active[id], transfer.waitingForChoice != nil else { return }
        active[id] = nil
        queued.removeAll { $0 == id }
        if let panel = transfer.panel { window?.endSheet(panel, returnCode: .cancel) }
        onStatus?("Загрузка отменена")
        DispatchQueue.main.async { [weak self] in self?.showNext() }
    }

    private func showNext() {
        guard let window, window.attachedSheet == nil,
              let id = queued.first, let transfer = active[id] else { return }
        queued.removeFirst()
        let panel = NSSavePanel()
        panel.title = "Сохранить загрузку"
        panel.prompt = "Сохранить"
        panel.nameFieldStringValue = transfer.filename
        transfer.panel = panel
        panel.beginSheetModal(for: window) { [weak self, weak transfer] result in
            guard let self, let transfer, self.active[id] === transfer else { return }
            transfer.waitingForChoice?.cancel()
            transfer.waitingForChoice = nil
            transfer.panel = nil
            if result == .OK, let url = panel.url { self.receive(id, transfer: transfer, destination: url) }
            else { self.reject(id, transfer: transfer, status: "Загрузка отменена") }
            // The current sheet may still be detaching when its callback runs.
            DispatchQueue.main.async { [weak self] in self?.showNext() }
        }
    }

    private func reject(_ id: UUID, transfer: Transfer, status: String) {
        let socket = transfer.socket
        active[id] = nil
        Task.detached {
            try? WebKitDownloadChannel.write(WebKitDownloadChannel.Decision.cancel, on: socket, timeout: 2)
            WebKitDownloadChannel.stop(socket)
        }
        onStatus?(status)
    }

    private func receive(_ id: UUID, transfer: Transfer, destination: URL) {
        let file: WebKitDownloadFile
        do { file = try WebKitDownloadFile(destination: destination) }
        catch {
            reject(id, transfer: transfer, status: "Не удалось создать файл. Проверь разрешения и имя.")
            return
        }
        transfer.file = file
        let socket = transfer.socket
        onStatus?("Файл загружается…")
        transfer.task = Task { @MainActor [weak self, weak transfer] in
            let incoming = await Task.detached { () -> FileHandle? in
                do {
                    try WebKitDownloadChannel.write(WebKitDownloadChannel.Decision.accept, on: socket, timeout: 2)
                    while !Task.isCancelled {
                        do { return try ProxyRelayPrivatePipe.receiveDescriptor(from: socket.fileDescriptor, timeout: 4) }
                        catch ProxyRelayPrivatePipe.Failure.timeout { continue }
                    }
                } catch { return nil }
                return nil
            }.value
            guard let self, let transfer, self.active[id] === transfer, !Task.isCancelled else { return }
            guard let incoming else {
                self.finish(id, transfer: transfer, result: .failed)
                return
            }
            do {
                let staging = try file.openNewStagingFile()
                let copy = Task.detached {
                    try WebKitDownloadChannel.copyPayload(incoming, to: staging)
                }
                transfer.copying = copy
                let peer = Task.detached { [weak self] in
                    WebKitDownloadChannel.waitForPeerClose(socket)
                    if !Task.isCancelled {
                        copy.cancel()
                        await self?.deliveryLost(id)
                    }
                }
                defer { peer.cancel() }
                try await copy.value
                guard self.active[id] === transfer, !Task.isCancelled else { return }
                guard WebKitDownloadChannel.peerReadyForResult(socket) else { throw WebKitDownloadChannel.Failure.failedCopy }
                try file.publish(expectedFile: staging)
                self.finish(id, transfer: transfer, result: .saved)
            } catch {
                if self.active[id] === transfer { self.finish(id, transfer: transfer, result: .failed) }
            }
        }
    }

    private func deliveryLost(_ id: UUID) {
        guard let transfer = active.removeValue(forKey: id) else { return }
        transfer.task?.cancel()
        transfer.file?.cleanup()
        WebKitDownloadChannel.stop(transfer.socket)
        onStatus?("Загрузка прервана")
    }

    private func finish(_ id: UUID, transfer: Transfer, result: WebKitDownloadChannel.Result) {
        active[id] = nil
        transfer.file?.cleanup()
        let socket = transfer.socket
        Task.detached {
            try? WebKitDownloadChannel.write(result, on: socket, timeout: 2)
            WebKitDownloadChannel.stop(socket)
        }
        switch result {
        case .saved: onStatus?("Файл сохранён")
        case .cancelled: onStatus?("Загрузка отменена")
        case .failed: onStatus?("Не удалось сохранить файл")
        }
    }

    func cancelActive() {
        let transfers = Array(active.values)
        active.removeAll()
        queued.removeAll()
        for transfer in transfers {
            transfer.task?.cancel()
            transfer.copying?.cancel()
            transfer.waitingForChoice?.cancel()
            WebKitDownloadChannel.stop(transfer.socket)
            if let panel = transfer.panel { window?.endSheet(panel, returnCode: .cancel) }
            transfer.file?.cleanup()
        }
        if !transfers.isEmpty { onStatus?("Загрузки отменены") }
    }

    func stop() {
        listening?.cancel()
        listening = nil
        WebKitDownloadChannel.stop(intake)
        onStatus = nil
        onFailure = nil
        cancelActive()
    }
}
#endif
