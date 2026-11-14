#if NEANTIK_WEBKIT_PROXY_PRODUCTION
import Darwin
import Foundation

/// The owned host supplies the only path WKDownload sees. The manager
/// approves the transfer and receives the completed read-only file.
@MainActor
final class WebKitDetachedDownloadHost {
    @MainActor
    private final class Transfer {
        let socket: FileHandle
        let directory: URL
        var resultTask: Task<Void, Never>?
        var delivery: ((WebKitDownloads.State) -> Void)?

        init(socket: FileHandle, directory: URL) {
            self.socket = socket
            self.directory = directory
        }

        func stop() {
            resultTask?.cancel()
            WebKitDownloadChannel.stop(socket)
            _ = Darwin.rmdir(directory.path)
        }
    }

    private let intake: FileHandle
    private let generation: UUID
    private let onCancel: (UUID) -> Void
    private let onUnavailable: () -> Void
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var lastOffer: (UUID, Task<Void, Never>)?
    private var transfers: [UUID: Transfer] = [:]

    init(intake: FileHandle, generation: UUID, onCancel: @escaping (UUID) -> Void,
         onUnavailable: @escaping () -> Void) {
        self.intake = intake
        self.generation = generation
        self.onCancel = onCancel
        self.onUnavailable = onUnavailable
    }

    var remote: WebKitDownloads.Remote {
        .init(begin: { [weak self] id, name, reply in
            guard let self else { reply(nil); return }
            self.begin(id, name: name, reply: reply)
        }, deliver: { [weak self] id, file, reply in
            guard let self else { reply(.failed); return }
            self.deliver(id, file: file, reply: reply)
        }, cancel: { [weak self] id in
            self?.cancel(id)
        }, dispose: { [weak self] id in
            self?.stop(id)
        })
    }

    private func begin(_ id: UUID, name: String, reply: @escaping @MainActor (URL?) -> Void) {
        let offer = WebKitDownloadChannel.Offer(generation: generation, id: id, filename: name)
        let intake = intake
        // WebKit supplies at most four active transfers. Serialize intake
        // descriptor offers while each decision uses its own socket.
        let previous = lastOffer?.1
        let task = Task { @MainActor [weak self] in
            defer { if self?.lastOffer?.0 == id { self?.lastOffer = nil } }
            if let previous { await previous.value }
            guard !Task.isCancelled, let self else { return }
            let socket = await Task.detached {
                try? WebKitDownloadChannel.offer(offer, on: intake, timeout: 2)
            }.value
            guard !Task.isCancelled, self.pending.removeValue(forKey: id) != nil else {
                if let socket { WebKitDownloadChannel.stop(socket) }
                return
            }
            guard let socket else {
                reply(nil)
                self.onUnavailable()
                return
            }
            do {
                let directory = try Self.makeDirectory()
                let transfer = Transfer(socket: socket, directory: directory)
                self.transfers[id] = transfer
                self.awaitDecision(id, transfer: transfer, reply: reply)
            } catch {
                WebKitDownloadChannel.stop(socket)
                reply(nil)
            }
        }
        pending[id] = task
        lastOffer = (id, task)
    }

    private static func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let template = root.appendingPathComponent("neantik-webkit-download.XXXXXXXX").path
        var bytes = Array(template.utf8CString)
        guard let path = bytes.withUnsafeMutableBufferPointer({ p -> String? in
            guard let base = p.baseAddress, let result = mkdtemp(base) else { return nil }
            return String(cString: result)
        }) else { throw CocoaError(.fileWriteUnknown) }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700, info.st_uid == geteuid() else {
            _ = Darwin.rmdir(path)
            throw CocoaError(.fileWriteUnknown)
        }
        return directory
    }

    private func awaitDecision(_ id: UUID, transfer: Transfer, reply: @escaping @MainActor (URL?) -> Void) {
        let socket = transfer.socket
        transfer.resultTask = Task.detached { [weak self, weak transfer] in
            var decision: WebKitDownloadChannel.Decision?
            while !Task.isCancelled {
                do {
                    decision = try WebKitDownloadChannel.read(WebKitDownloadChannel.Decision.self, on: socket, timeout: 4)
                    break
                } catch ProxyRelayPrivatePipe.Failure.timeout {
                    continue
                } catch { break }
            }
            guard !Task.isCancelled else { return }
            let selected = decision
            let accepted = await MainActor.run { [weak self, weak transfer] in
                guard let self, let transfer, self.transfers[id] === transfer else { return false }
                guard selected == .accept else { reply(nil); return false }
                reply(transfer.directory.appendingPathComponent("download"))
                return true
            }
            guard accepted else { return }
            var result: WebKitDownloadChannel.Result?
            while !Task.isCancelled {
                do {
                    result = try WebKitDownloadChannel.read(WebKitDownloadChannel.Result.self, on: socket, timeout: 4)
                    break
                } catch ProxyRelayPrivatePipe.Failure.timeout {
                    continue
                } catch { break }
            }
            guard !Task.isCancelled else { return }
            let completed = result
            await MainActor.run { [weak self, weak transfer] in
                guard let self, let transfer, self.transfers[id] === transfer else { return }
                if let delivery = transfer.delivery {
                    delivery(completed == .saved ? .finished : completed == .cancelled ? .cancelled : .failed)
                } else {
                    self.onCancel(id)
                }
            }
        }
    }

    private func deliver(_ id: UUID, file: FileHandle, reply: @escaping @MainActor (WebKitDownloads.State) -> Void) {
        guard let transfer = transfers[id] else { reply(.failed); return }
        transfer.delivery = reply
        let socket = transfer.socket
        Task.detached {
            do {
                try ProxyRelayPrivatePipe.sendDescriptor(file.fileDescriptor, to: socket.fileDescriptor, timeout: 4)
            } catch {
                WebKitDownloadChannel.stop(socket)
            }
        }
    }

    private func stop(_ id: UUID) {
        pending.removeValue(forKey: id)?.cancel()
        transfers.removeValue(forKey: id)?.stop()
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.cancel()
        guard let transfer = transfers[id] else { return }
        transfer.resultTask?.cancel()
        WebKitDownloadChannel.stop(transfer.socket)
    }

    func stop() {
        WebKitDownloadChannel.stop(intake)
        for id in Array(pending.keys) + Array(transfers.keys) { stop(id) }
    }
}
#endif
