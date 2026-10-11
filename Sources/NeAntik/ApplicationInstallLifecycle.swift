import Darwin
import DirectInstallFilesystem
import Foundation

/// Process lifetime, before any GUI/MCP/relay storage initialization. No caller
/// supplied path, argv, profile root or MCP request chooses the install scope.
@MainActor
enum ApplicationInstallLifecycle {
    private static var participant: InstallLifecycleParticipant?
    static func enter() throws {
        guard participant == nil else { return }
        var buffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0,
              let pointer = realpath(String(cString: buffer), nil) else { throw ApplicationInstallLifecycleError.unavailable }
        defer { free(pointer) }
        let executableURL = URL(fileURLWithPath: String(cString: pointer))
        // Unbundled SwiftPM executables are not an installed .app target.
        guard let app = NeAntikLaunchIntent.applicationBundleURL(forExecutablePath: executableURL.path) else {
            guard Bundle.main.bundleURL.pathExtension != "app" else { throw ApplicationInstallLifecycleError.unavailable }
            return
        }
        let base = URL(fileURLWithPath: "/private/tmp/neantik-update-lifecycle-\(geteuid())")
        let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ApplicationInstallLifecycleError.unavailable }; defer { close(parent) }
        guard mkdirat(parent, base.lastPathComponent, 0o700) == 0 || errno == EEXIST else { throw ApplicationInstallLifecycleError.unavailable }
        // Validate the per-UID parent before creating a child; never repair it.
        var s = stat()
        let fd = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ApplicationInstallLifecycleError.unavailable }; defer { close(fd) }
        guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o7777 == 0o700, s.st_flags == 0 else {
            throw ApplicationInstallLifecycleError.unavailable
        }
        do {
            let namespace = base.appendingPathComponent(try InstallLifecycle.namespaceName(installationURL: app))
            participant = try InstallLifecycleParticipant(namespaceURL: namespace) {
                try InstallLifecycle.requireNoPendingTransaction(installationURL: app)
            }
        } catch {
            #if DEBUG
            if let error = error as? InstallFilesystemError {
                DirectUpdateCandidateBootstrap.recordQualificationRefusal("ordinary-lifecycle-" + String(describing: error))
            }
            #endif
            throw ApplicationInstallLifecycleError.unavailable
        }
    }
    static func requireNewWork() throws {
        do {
            try ApplicationUpdateAdmission.shared.requireNewWork()
            try participant?.requireNewWork()
        }
        catch { throw ApplicationInstallLifecycleError.unavailable }
    }
}

enum ApplicationInstallLifecycleError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "NeAntik готовится к обновлению или не может проверить его состояние. Закрой другие экземпляры приложения и повтори запуск. Если ошибка сохраняется, сохрани данные профилей и обратись в поддержку."
    }
}
