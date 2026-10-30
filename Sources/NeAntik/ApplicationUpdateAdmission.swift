import Foundation

/// MainActor admission covers the whole operation, including detached work and
/// publication. Cancelling a Task or dismissing a view never ends its lease.
@MainActor
final class ApplicationUpdateAdmission {
    static let shared = ApplicationUpdateAdmission()
    private var activities = Set<UUID>()
    private var update: UUID?
    var isUpdating: Bool { update != nil }
    var activeCount: Int { activities.count }

    func requireNewWork() throws {
        guard update == nil else { throw ApplicationUpdateAdmissionError.updating }
    }
    func beginActivity() throws -> UUID {
        try requireNewWork()
        let token = UUID(); activities.insert(token); return token
    }
    func finishActivity(_ token: UUID) { activities.remove(token) }
    func acquireUpdate() throws -> UUID {
        try requireNewWork()
        guard activities.isEmpty else { throw ApplicationUpdateAdmissionError.busy }
        let token = UUID(); update = token; return token
    }
    func releaseUpdate(_ token: UUID) {
        guard update == token else { return }
        update = nil
    }
}

enum ApplicationUpdateAdmissionError: LocalizedError {
    case busy, updating
    var errorDescription: String? {
        switch self {
        case .busy: "Операция с данными ещё выполняется. Дождись её завершения и снова открой обновление."
        case .updating: "NeAntik готовится к обновлению. Заверши или отмени его перед другой операцией."
        }
    }
}
