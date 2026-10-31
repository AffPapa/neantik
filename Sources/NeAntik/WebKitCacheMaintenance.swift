import Foundation
import WebKit

/// HTTP caches only. FetchCache/ServiceWorkers, cookies and persistent website
/// databases are deliberately excluded; no private WebKit directories are read.
@MainActor
enum WebKitCacheMaintenance {
    static let dataTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]

    static func clear(profileID: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        // The callback has no error parameter and cannot be cancelled. Keep the
        // store alive and let the caller retain admission until real completion.
        defer { withExtendedLifetime(store) {} }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }
}

enum WebKitCacheMaintenanceError: LocalizedError, Equatable {
    case wrongEngine, authorityChangedAfterCompletion
    var errorDescription: String? {
        switch self {
        case .wrongEngine: "Эта операция доступна только для профиля WebKit."
        case .authorityChangedAfterCompletion: "Очистка WebKit завершилась, но защита операции изменилась. Кэш мог быть удалён; не запускай этот профиль в другом экземпляре NeAntik одновременно. Данные сайтов не входили в очистку."
        }
    }
}
