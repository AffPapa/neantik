import Foundation
import Testing
@testable import NeAntik

@MainActor
struct WorkspacePreferenceStoreTests {
    @Test func densityMetricsKeepTheCompactRowSmaller() {
        #expect(ProfileRowDensity.compact.verticalPadding == 3)
        #expect(ProfileRowDensity.comfortable.verticalPadding == 7)
        #expect(ProfileRowDensity.compact.minimumRowHeight == 50)
        #expect(ProfileRowDensity.comfortable.minimumRowHeight == 62)
        for density in ProfileRowDensity.allCases {
            #expect(density.minimumRowHeight - 2 * density.verticalPadding >= 44)
        }
    }

    @Test func persistsOnlyTheSelectedRowDensity() throws {
        let suite = "NeAntik.WorkspacePreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WorkspacePreferenceStore(defaults: defaults)
        #expect(store.rowDensity == .comfortable)

        store.rowDensity = .compact

        let reloaded = WorkspacePreferenceStore(defaults: defaults)
        #expect(reloaded.rowDensity == .compact)
        #expect(
            defaults.string(
                forKey: WorkspacePreferenceStore.rowDensityKey
            ) == ProfileRowDensity.compact.rawValue
        )
    }

    @Test func invalidPersistedDensityFailsClosedToComfortable() throws {
        let suite = "NeAntik.WorkspacePreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            "unknown-density",
            forKey: WorkspacePreferenceStore.rowDensityKey
        )

        let store = WorkspacePreferenceStore(defaults: defaults)

        #expect(store.rowDensity == .comfortable)
        #expect(
            defaults.object(
                forKey: WorkspacePreferenceStore.rowDensityKey
            ) == nil
        )
    }

    @Test func resetRestoresAndPersistsComfortableDensity() throws {
        let suite = "NeAntik.WorkspacePreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspacePreferenceStore(
            defaults: defaults,
            initialRowDensity: .compact
        )

        store.resetInterface()

        #expect(store.rowDensity == .comfortable)
        #expect(
            defaults.string(
                forKey: WorkspacePreferenceStore.rowDensityKey
            ) == ProfileRowDensity.comfortable.rawValue
        )
    }
}
