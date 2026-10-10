import Foundation

enum ProfilePrivacyAvailability: String, Equatable, Sendable {
    case available
    case unavailable
    case unknown
    case failed
    case timedOut

    var title: String {
        switch self {
        case .available:
            "Доступно"
        case .unavailable:
            "Недоступно"
        case .unknown:
            "Не проверено"
        case .failed:
            "Ошибка чтения"
        case .timedOut:
            "Истекло время ожидания"
        }
    }
}

enum ProfilePrivacyPermissionState: String, Equatable, Sendable {
    case granted
    case denied
    case prompt
    case unavailable
    case unknown

    var title: String {
        switch self {
        case .granted:
            "Разрешено"
        case .denied:
            "Запрещено"
        case .prompt:
            "Запросит разрешение"
        case .unavailable:
            "Недоступно"
        case .unknown:
            "Не проверено"
        }
    }
}

struct ProfilePrivacyPanelSnapshot: Equatable, Sendable {
    static let empty = Self(
        profileID: nil,
        observedAt: nil,
        mediaDevices: .unknown,
        mediaDeviceCount: nil,
        permissionsAPI: .unknown,
        camera: .unknown,
        microphone: .unknown
    )

    let profileID: UUID?
    let observedAt: Date?
    let mediaDevices: ProfilePrivacyAvailability
    let mediaDeviceCount: Int?
    let permissionsAPI: ProfilePrivacyAvailability
    let camera: ProfilePrivacyPermissionState
    let microphone: ProfilePrivacyPermissionState

    static func from(capture: FingerprintCapture) -> Self {
        Self(
            profileID: capture.profileID,
            observedAt: capture.capturedAt,
            mediaDevices: mediaAvailability(capture.values),
            mediaDeviceCount: SiteCompatibilityAssessment.mediaState(capture.values) == .observed
                ? boundedCount(capture.values["media_device_count"]) : nil,
            permissionsAPI: availability(capture.values["permissions_api"]),
            camera: permission(capture.values["permission_camera"]),
            microphone: permission(capture.values["permission_microphone"])
        )
    }

    private static func mediaAvailability(_ values: [String: String]) -> ProfilePrivacyAvailability {
        switch SiteCompatibilityAssessment.mediaState(values) {
        case .observed: .available
        case .unavailable: .unavailable
        case .failed: .failed
        case .timedOut: .timedOut
        case .notChecked: .unknown
        }
    }

    private static func availability(_ value: String?)
        -> ProfilePrivacyAvailability
    {
        switch value {
        case "available":
            .available
        case "unavailable":
            .unavailable
        default:
            .unknown
        }
    }

    private static func permission(_ value: String?)
        -> ProfilePrivacyPermissionState
    {
        switch value {
        case "granted":
            .granted
        case "denied":
            .denied
        case "prompt":
            .prompt
        case "unavailable":
            .unavailable
        default:
            .unknown
        }
    }

    private static func boundedCount(_ value: String?) -> Int? {
        guard let value, let count = Int(value), (0...256).contains(count)
        else {
            return nil
        }
        return count
    }
}
