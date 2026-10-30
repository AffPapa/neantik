import Foundation

/// Safe, current-process evidence that local profile metadata was recovered.
/// It carries no paths, rejected bytes, profile IDs, or browser data.
struct ProfileRecoveryNotice: Equatable, Sendable {
    let profileMetadataRecovered: Bool
    let folderMetadataRecovered: Bool

    var detail: String {
        switch (profileMetadataRecovered, folderMetadataRecovered) {
        case (true, true):
            "Списки профилей и папок восстановлены из предыдущих локальных копий. Данные браузеров не менялись."
        case (true, false):
            "Список профилей восстановлен из предыдущей локальной копии. Данные браузеров не менялись."
        case (false, true):
            "Список папок восстановлен из предыдущей локальной копии. Профили и данные браузеров не менялись."
        case (false, false):
            "Восстановление не выполнялось."
        }
    }

    var accessibilityLabel: String {
        "Восстановление метаданных в текущем запуске. " + detail
    }
}
