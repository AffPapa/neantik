import Combine
import Foundation

/// One admission slot for manager windows, including asynchronous proxy
/// preparation. Pressure only blocks new starts; it never stops a browser.
@MainActor
final class ManagerLaunchAdmission: ObservableObject {
    static let shared = ManagerLaunchAdmission()
    @Published private(set) var pressured = false
    @Published private var active: (profileID: UUID, token: UUID)?
    var isPreparing: Bool { active != nil }
    var preparingProfileID: UUID? { active?.profileID }
    private var nextStart = Date.distantPast
    private var source: DispatchSourceMemoryPressure?
    private let thermalState: () -> ProcessInfo.ThermalState

    init(observePressure: Bool = true,
         thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) {
        self.thermalState = thermalState
        if observePressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                let pressure = source?.data.contains(.warning) == true || source?.data.contains(.critical) == true
                Task { @MainActor [weak self] in self?.pressured = pressure }
            }
            source.resume()
            self.source = source
        }
    }
    deinit { source?.cancel() }
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
        if launched { nextStart = now.addingTimeInterval(1) }
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
