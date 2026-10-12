import AppKit
import Combine
import Darwin
import DirectUpdateCore
import Foundation

protocol ApplicationUpdateTransport: Sendable {
    func inspect(archive: URL, manifest: Data) async throws -> DirectUpdateOwnerOffer
    func consentAndHandoff() async throws
    func cancelAndDrain() async throws
}
extension DirectUpdateOwnerClient: ApplicationUpdateTransport {}

/// App-owned state survives view dismissal. The local fence is released only
/// after the owner has drained, or retained until ordinary application exit.
@MainActor
final class ApplicationUpdateController: ObservableObject {
    enum Phase: Equatable { case idle, discovering, checking, offered, cancelling, committing, restartRequired }
    @Published private(set) var isPresented = false
    @Published private(set) var phase = Phase.idle
    @Published private(set) var offeredVersion: String?
    @Published private(set) var message: String?
    @Published private(set) var manifestVersion: String?
    let channelEnabled: Bool
    private let admission: ApplicationUpdateAdmission
    private var fence: UUID?
    private var client: (any ApplicationUpdateTransport)?
    private let makeClient: @MainActor () -> any ApplicationUpdateTransport
    private let terminate: @MainActor () -> Void
    private var inspection: Task<Void, Never>?
    private var archiveAccess: URL?
    private var cleanupUnconfirmed = false
    private var terminationAfterDismissal = false
    private var offerExpiration: Task<Void, Never>?
    private let offerLifetime: Duration
    private var retrievedManifest: RetrievedUpdateManifest?
    private var discovery: Task<Void, Never>?
    private let fetchManifest: @Sendable () async throws -> RetrievedUpdateManifest

    init(channelEnabled: Bool = UpdateChannelConfiguration.fromBundle().isEnabled,
         admission: ApplicationUpdateAdmission? = nil,
         makeClient: (@MainActor () -> any ApplicationUpdateTransport)? = nil,
         terminate: (@MainActor () -> Void)? = nil,
         offerLifetime: Duration = .seconds(240),
         fetchManifest: (@Sendable () async throws -> RetrievedUpdateManifest)? = nil) {
        self.channelEnabled = channelEnabled; self.admission = admission ?? .shared
        self.makeClient = makeClient ?? { DirectUpdateOwnerClient() }
        self.terminate = terminate ?? { NSApplication.shared.terminate(nil) }
        self.offerLifetime = offerLifetime
        let installedApp = Bundle.main.bundleURL
        self.fetchManifest = fetchManifest ?? {
            try await SignedUpdateManifestFetcher().fetchInstalled(app: installedApp)
        }
    }
    var holdsFence: Bool { fence != nil }
    var canClose: Bool { phase == .idle }
    var canCancel: Bool { phase == .discovering || phase == .checking || phase == .offered }
    var hasRetrievedManifest: Bool { retrievedManifest != nil }

    func present(workspaceIsBusy: Bool) {
        guard !isPresented, fence == nil else { return }
        message = nil; offeredVersion = nil; phase = .idle; cleanupUnconfirmed = false
        retrievedManifest = nil; manifestVersion = nil
        if channelEnabled {
            guard !workspaceIsBusy, !ManagerLaunchAdmission.shared.isPreparing else {
                message = "Закрой браузерные окна и дождись завершения операций с профилями. Затем снова открой обновление."
                isPresented = true; return
            }
            do { fence = try admission.acquireUpdate() }
            catch { message = error.localizedDescription }
        }
        isPresented = true
    }

    func checkForUpdates() {
        guard channelEnabled, holdsFence, phase == .idle else { return }
        phase = .discovering; message = nil; manifestVersion = nil; retrievedManifest = nil
        let fetch = fetchManifest
        discovery = Task { @MainActor in
            do {
                let manifest = try await fetch()
                try Task.checkCancellation()
                guard phase == .discovering else { return }
                if manifest.verified.isNewerThanInstalled {
                    retrievedManifest = manifest
                    manifestVersion = "\(manifest.verified.payload.version) (\(manifest.verified.payload.build))"
                    message = "Подпись описания обновления проверена. Выбери ZIP этого выпуска: приложение и архив будут проверены отдельно до установки."
                } else { message = "В подписанном канале нет версии новее установленной." }
                phase = .idle; discovery = nil
            } catch {
                guard phase == .discovering else { return }
                message = "Не удалось получить и проверить описание обновления. Повтори позже или выбери ZIP и подписанный manifest вручную."
                phase = .idle; discovery = nil
            }
        }
    }

    func chooseFiles() {
        guard channelEnabled, holdsFence, phase == .idle else { return }
        let archivePanel = NSOpenPanel()
        archivePanel.title = "Выбрать ZIP обновления NeAntik"
        archivePanel.message = "Выбери оригинальный ZIP из выпуска NeAntik. DMG здесь не используется."
        archivePanel.allowedContentTypes = [.zip]; archivePanel.canChooseDirectories = false
        archivePanel.allowsMultipleSelection = false
        guard archivePanel.runModal() == .OK, let archive = archivePanel.url else { return }
        if retrievedManifest != nil {
            beginInspection(archive: archive)
            return
        }
        let manifestPanel = NSOpenPanel()
        manifestPanel.title = "Выбрать подписанный manifest обновления"
        manifestPanel.message = "Нужен manifest этого же выпуска. Обычный файл SHA-256 его не заменяет."
        manifestPanel.allowedContentTypes = [.json]; manifestPanel.canChooseDirectories = false
        manifestPanel.allowsMultipleSelection = false
        guard manifestPanel.runModal() == .OK, let manifest = manifestPanel.url else { return }
        beginInspection(archive: archive, manifest: manifest)
    }

    func beginInspection(archive: URL) {
        guard let retrievedManifest else { return }
        beginInspection(archive: archive, manifestAccess: nil, read: { retrievedManifest.bytes })
    }

    func beginInspection(archive: URL, manifest: URL) {
        guard channelEnabled, holdsFence, phase == .idle else { return }
        beginInspection(archive: archive, manifestAccess: manifest, read: { try Self.readManifest(manifest) })
    }

    private func beginInspection(archive: URL, manifestAccess: URL?, read: @escaping @Sendable () throws -> Data) {
        guard channelEnabled, holdsFence, phase == .idle else { return }
        if archive.startAccessingSecurityScopedResource() { archiveAccess = archive }
        let manifestScoped = manifestAccess?.startAccessingSecurityScopedResource() ?? false
        let client = makeClient(); self.client = client
        // The owner bounds consent to 300 seconds from operation start. Stop
        // offering before that deadline; never display a dead owner as ready.
        let offerDeadline = ContinuousClock.now.advanced(by: offerLifetime)
        phase = .checking; message = nil
        inspection = Task { @MainActor in
            defer { if manifestScoped { manifestAccess?.stopAccessingSecurityScopedResource() } }
            do {
                let bytes = try await Task.detached(priority: .utility) { try read() }.value
                try Task.checkCancellation()
                let offer = try await client.inspect(archive: archive, manifest: bytes)
                guard phase != .cancelling else { return }
                offeredVersion = "\(offer.version) (\(offer.build))"; phase = .offered
                offerExpiration = Task { @MainActor [weak self] in
                    do { try await ContinuousClock().sleep(until: offerDeadline) }
                    catch { return }
                    guard let self, self.phase == .offered else { return }
                    self.phase = .cancelling
                    await self.drain(client, failureMessage: "Время подтверждения истекло. Проверь файлы ещё раз перед установкой.")
                }
            } catch {
                // A later no-session drain must not erase a previous unknown
                // cleanup result, including an inspection cancelled by UI.
                if error as? DirectUpdateOwnerClientError == .cleanup { cleanupUnconfirmed = true }
                guard phase != .cancelling else { return }
                // Selected private paths and native diagnostics never enter UI.
                if cleanupUnconfirmed {
                    phase = .restartRequired
                    message = "Завершение установщика не подтверждено. Закрой NeAntik и повтори запуск перед новой попыткой."
                } else {
                    phase = .cancelling
                    await drain(client, failureMessage: "Файлы обновления не прошли проверку или установке мешает другой экземпляр NeAntik. Закрой его и выбери оригинальные файлы выпуска.")
                }
            }
        }
    }

    func cancel() {
        offerExpiration?.cancel(); offerExpiration = nil
        if phase == .discovering {
            phase = .cancelling; message = "Завершение проверки…"
            let pending = discovery; pending?.cancel()
            Task { @MainActor in
                await pending?.value
                discovery = nil; retrievedManifest = nil; manifestVersion = nil
                phase = .idle; message = nil
            }
            return
        }
        guard canCancel, let client else { return }
        phase = .cancelling; message = "Завершение проверки…"
        let checking = inspection
        checking?.cancel()
        Task { @MainActor in
            await checking?.value
            await drain(client, failureMessage: nil)
        }
    }
    private func drain(_ client: any ApplicationUpdateTransport, failureMessage: String?) async {
        do {
            try await client.cancelAndDrain()
            guard !cleanupUnconfirmed else { throw DirectUpdateOwnerClientError.cleanup }
            self.client = nil; inspection = nil; stopArchiveAccess()
            // Keep this modal's admission through a retry; Close releases it.
            phase = .idle; offeredVersion = nil; message = failureMessage
        } catch {
            cleanupUnconfirmed = true
            phase = .restartRequired
            message = "Не удалось подтвердить остановку установщика. Закрой NeAntik и повтори запуск. Другие операции пока заблокированы."
        }
    }
    func installAndRestart() {
        guard phase == .offered, holdsFence, let client else { return }
        offerExpiration?.cancel(); offerExpiration = nil
        phase = .committing; message = "Подготовка к перезапуску…"
        Task { @MainActor in
            do {
                try await client.consentAndHandoff()
                // Accepted is consent, not installation success. The owner
                // waits for actual manager exit before the filesystem swap.
                dismissForTermination()
            } catch {
                phase = .restartRequired
                message = "Установщик не подтвердил перезапуск. Закрой NeAntik и проверь версию при следующем запуске перед повторной установкой."
            }
        }
    }
    /// AppKit refuses termination while a SwiftUI sheet is presented. Keep
    /// install authority fenced until process exit, but dismiss the sheet first.
    func dismissForTermination() {
        guard phase == .committing || phase == .restartRequired else { return }
        terminationAfterDismissal = true
        isPresented = false
    }
    func sheetDidDisappear() {
        guard terminationAfterDismissal, !isPresented else { return }
        terminationAfterDismissal = false
        Task { @MainActor in
            await Task.yield()
            terminate()
        }
    }
    func close() {
        guard canClose else { return }
        stopArchiveAccess()
        if let fence { admission.releaseUpdate(fence) }
        fence = nil; isPresented = false; message = nil
        retrievedManifest = nil; manifestVersion = nil
    }
    private func stopArchiveAccess() {
        archiveAccess?.stopAccessingSecurityScopedResource(); archiveAccess = nil
    }
    nonisolated static func readManifest(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DirectUpdateOwnerClientError.transport }
        defer { Darwin.close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
              s.st_size > 0, s.st_size <= 128 * 1024 else { throw DirectUpdateOwnerClientError.transport }
        var data = Data(count: Int(s.st_size)); var offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw DirectUpdateOwnerClientError.transport }
            offset += n
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0 else { throw DirectUpdateOwnerClientError.transport }
        return data
    }
}
