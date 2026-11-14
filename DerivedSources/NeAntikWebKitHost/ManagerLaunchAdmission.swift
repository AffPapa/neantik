import Combine
import Darwin
import Foundation

/// One admission slot for manager windows, including asynchronous proxy
/// preparation. Pressure only blocks new starts; it never stops a browser.
@MainActor
final class ManagerLaunchAdmission: ObservableObject {
    static let shared = ManagerLaunchAdmission()
    @Published private(set) var pressured = false
    @Published private var active: (profileID: UUID, token: UUID)?
    private var activeCancellation: (() -> Void)?
    var isPreparing: Bool { active != nil }
    var preparingProfileID: UUID? { active?.profileID }
    var canCancelPreparation: Bool { activeCancellation != nil }
    private var nextStart = Date.distantPast
    private var source: DispatchSourceMemoryPressure?
    private let thermalState: () -> ProcessInfo.ThermalState
    private let pressureLevel: (() -> Int32?)?

    init(observePressure: Bool = true,
         thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         pressureLevel: (() -> Int32?)? = nil) {
        self.thermalState = thermalState
        if let pressureLevel {
            self.pressureLevel = pressureLevel
        } else if observePressure {
            self.pressureLevel = Self.systemPressureLevel
        } else {
            self.pressureLevel = nil
        }
        refreshPressure()
        if observePressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let flags = source?.data else { return }
                MainActor.assumeIsolated {
                    self?.refreshPressure(eventFallback: flags.contains(.warning) || flags.contains(.critical))
                }
            }
            source.resume()
            self.source = source
        }
    }
    deinit { source?.cancel() }

    nonisolated private static func systemPressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return level
    }

    private func refreshPressure(eventFallback: Bool? = nil) {
        // This sysctl exposes Dispatch notification flags, not XNU's internal enum.
        let observed: Bool?
        switch pressureLevel?() {
        case 1: observed = false
        case 2, 4: observed = true
        default: observed = eventFallback
        }
        if let observed, pressured != observed { pressured = observed }
    }

    func requireSafePressure() throws {
        #if NEANTIK_WEBKIT_STANDALONE_HOST
        // The child has no manager install controller. The signed parent owns
        // that admission; the child retains its own thermal/pressure refusal.
        try ApplicationUpdateAdmission.shared.requireNewWork()
        #else
        try ApplicationInstallLifecycle.requireNewWork()
        #endif
        // Use one observation: critical followed by serious must not pass two
        // separate inequality checks while the system temperature changes.
        refreshPressure()
        let thermal = thermalState()
        guard !pressured, thermal != .serious, thermal != .critical else {
            throw ManagerLaunchAdmissionError.pressure
        }
    }
    func begin(profileID: UUID, now: Date = Date()) throws -> UUID {
        try requireSafePressure()
        guard active == nil, now >= nextStart else { throw ManagerLaunchAdmissionError.busy }
        let token = UUID(); active = (profileID, token); return token
    }
    func finish(token: UUID, launched: Bool = false, now: Date = Date()) {
        guard active?.token == token else { return }
        active = nil
        activeCancellation = nil
        if launched { nextStart = now.addingTimeInterval(1) }
    }
    func registerCancellation(token: UUID, handler: @escaping () -> Void) {
        guard active?.token == token else { return }
        activeCancellation = handler
    }
    @discardableResult
    func cancelActivePreparation() -> Bool {
        guard let activeCancellation else { return false }
        activeCancellation()
        return true
    }
    func setPressureForTesting(_ value: Bool) { pressured = value }
}

enum ManagerLaunchAdmissionError: LocalizedError {
    case pressure, busy
    var errorDescription: String? {
        switch self {
        case .pressure: "Новый запуск приостановлен: macOS сообщает о нехватке памяти или высокой температуре. Дождись снижения нагрузки и повтори. Открытые профили продолжают работать."
        case .busy: "Другой запуск ещё подготавливается. Дождись его завершения или отмени подготовку; затем повтори запуск."
        }
    }
}
