import Combine
import Foundation

@MainActor
final class WorkspacePreferenceStore: ObservableObject {
    static let rowDensityKey = "workspace.profileRowDensity"

    // A one-shot navigation request, never a persisted preference.
    @Published private(set) var shortcutReferenceRequest: UUID?

    func requestShortcutReference() {
        shortcutReferenceRequest = UUID()
    }

    func consumeShortcutReferenceRequest() -> Bool {
        guard shortcutReferenceRequest != nil else { return false }
        shortcutReferenceRequest = nil
        return true
    }

    @Published var rowDensity: ProfileRowDensity {
        didSet {
            guard rowDensity != oldValue else { return }
            defaults.set(rowDensity.rawValue, forKey: Self.rowDensityKey)
        }
    }

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        initialRowDensity: ProfileRowDensity? = nil
    ) {
        self.defaults = defaults
        if let initialRowDensity {
            rowDensity = initialRowDensity
        } else if let rawValue = defaults.string(
            forKey: Self.rowDensityKey
        ), let persisted = ProfileRowDensity(rawValue: rawValue) {
            rowDensity = persisted
        } else {
            rowDensity = .comfortable
            if defaults.object(forKey: Self.rowDensityKey) != nil {
                defaults.removeObject(forKey: Self.rowDensityKey)
            }
        }
    }

    func resetInterface() {
        rowDensity = .comfortable
    }
}
