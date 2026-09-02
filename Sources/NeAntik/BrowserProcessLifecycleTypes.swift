import Darwin
import Foundation

enum BrowserProcessLockPhase: String, Codable, Equatable, Sendable {
    case starting
    case running
}

struct BrowserProcessLock: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let ownerToken: UUID?
    let managerPID: pid_t?
    let phase: BrowserProcessLockPhase
    let pid: pid_t
    let executablePath: String
    let browserDataPath: String
    let createdAt: Date

    init(
        pid: pid_t,
        executablePath: String,
        browserDataPath: String,
        createdAt: Date,
        schemaVersion: Int = 1,
        ownerToken: UUID? = nil,
        managerPID: pid_t? = nil,
        phase: BrowserProcessLockPhase = .running
    ) {
        self.schemaVersion = schemaVersion
        self.ownerToken = ownerToken
        self.managerPID = managerPID
        self.phase = phase
        self.pid = pid
        self.executablePath = executablePath
        self.browserDataPath = browserDataPath
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case ownerToken
        case managerPID
        case phase
        case pid
        case executablePath
        case browserDataPath
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        ownerToken = try container.decodeIfPresent(
            UUID.self,
            forKey: .ownerToken
        )
        managerPID = try container.decodeIfPresent(
            pid_t.self,
            forKey: .managerPID
        )
        phase =
            try container.decodeIfPresent(
                BrowserProcessLockPhase.self,
                forKey: .phase
            ) ?? .running
        pid = try container.decode(pid_t.self, forKey: .pid)
        executablePath = try container.decode(
            String.self,
            forKey: .executablePath
        )
        browserDataPath = try container.decode(
            String.self,
            forKey: .browserDataPath
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

enum BrowserProcessIdentityInspection: Equatable, Sendable {
    case expected
    case unrelated
    case unknown
}

enum BrowserDataProcessInspection: Equatable, Sendable {
    case found
    case absent
    case unknown
}

enum BrowserProfileDeletionBlockReason: Equatable, Sendable {
    case managedProcess
    case leasePresent
    case unsafeLease
    case browserDataInUse
    case inspectionUnavailable
}

struct BrowserProfileDeletionBlockedError: LocalizedError, Equatable {
    let reason: BrowserProfileDeletionBlockReason

    var errorDescription: String? {
        switch reason {
        case .managedProcess:
            "Нельзя удалить профиль, пока его браузер запущен."
        case .leasePresent:
            "Профиль используется другим экземпляром NeAntik. Закрой браузер и повтори удаление."
        case .unsafeLease:
            "Файл состояния запуска не прошёл проверку безопасности. Данные профиля не изменены."
        case .browserDataInUse:
            "Данные профиля сейчас используются браузером. Закрой его окно и повтори удаление."
        case .inspectionUnavailable:
            "NeAntik не смог доказать, что данные профиля свободны. Удаление безопасно отменено."
        }
    }
}

struct BrowserProfileDeletedError: LocalizedError, Equatable {
    var errorDescription: String? {
        "Этот профиль уже удалён другим экземпляром NeAntik. Обнови список профилей."
    }
}

enum BrowserProfileProcessState: Equatable, Sendable {
    case stopped
    case checking
    case managed
    case closing
    case forceStopAvailable
    case externalVerified
    case externalManualOnly
    case externalUnverified
    case recoveryRequired

    var isRunning: Bool {
        self != .stopped
    }

    /// True only when NeAntik has positive evidence of a live browser.
    /// Transitional and recovery states remain blocked for safety, but must
    /// not be presented to the user as running processes.
    var isConfirmedRunning: Bool {
        switch self {
        case .managed, .closing, .forceStopAvailable,
             .externalVerified, .externalManualOnly:
            true
        case .stopped, .checking, .externalUnverified, .recoveryRequired:
            false
        }
    }

    var canRequestStop: Bool {
        self != .checking &&
            self != .closing &&
            self != .forceStopAvailable &&
            self != .externalManualOnly &&
            self != .externalUnverified &&
            self != .recoveryRequired
    }

    var title: String {
        switch self {
        case .stopped:
            "Остановлен"
        case .checking:
            "Подготовка…"
        case .managed:
            "Запущен"
        case .closing:
            "Закрывается…"
        case .forceStopAvailable:
            "Не отвечает"
        case .externalVerified:
            "Запущен другим NeAntik"
        case .externalManualOnly:
            "Запущен вручную"
        case .externalUnverified:
            "Требуется закрыть вручную"
        case .recoveryRequired:
            "Профиль заблокирован для защиты данных"
        }
    }

    var guidance: String? {
        switch self {
        case .stopped, .managed:
            nil
        case .closing:
            "Chromium завершает работу. Профиль остаётся заблокированным до выхода процесса."
        case .forceStopAvailable:
            "Chromium не завершился вовремя. Принудительная остановка доступна отдельно и может повредить незаписанную сессию."
        case .checking:
            "NeAntik подготавливает данные профиля. Это займёт несколько секунд."
        case .externalVerified:
            "Профиль запущен другим экземпляром NeAntik. Его можно безопасно остановить здесь."
        case .externalManualOnly:
            "Профиль запущен другим экземпляром NeAntik. Закрой окно браузера вручную; профиль разблокируется автоматически."
        case .externalUnverified:
            "NeAntik видит работающий процесс, но не может безопасно подтвердить его. Закрой окно браузера вручную; профиль разблокируется автоматически."
        case .recoveryRequired:
            "Файл состояния запуска повреждён или недоступен. Закрой окно браузера вручную; NeAntik разблокирует профиль только после безопасной проверки."
        }
    }
}

enum BrowserStopPhase: Equatable, Sendable {
    case idle
    case closing(requestedAt: Date)
    case forceStopAvailable(requestedAt: Date)
    case completed(completedAt: Date, wasForced: Bool)
}

enum BrowserLaunchPurpose: Equatable, Sendable {
    case normal
    case fingerprintAudit(httpLoopbackPort: UInt16)
}
