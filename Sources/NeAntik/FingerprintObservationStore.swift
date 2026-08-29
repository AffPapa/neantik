import Combine
import Foundation

/// Session-scoped evidence shared by every NeAntik window.
///
/// The environment inspector remains the fail-closed authority: it checks the
/// observation's profile/runtime binding and age every time it builds UI.
@MainActor
final class FingerprintObservationStore: ObservableObject {
    @Published private var changeSequence: UInt64 = 0
    private var observations:
        [UUID: ValidatedProfileFingerprintObservation] = [:]

    func observation(
        for profileID: UUID
    ) -> ValidatedProfileFingerprintObservation? {
        observations[profileID]
    }

    func record(_ observation: ValidatedProfileFingerprintObservation) {
        guard observation.configurationRevision != nil else { return }
        observations[observation.profileID] = observation
        changeSequence &+= 1
    }

    func remove(profileID: UUID) {
        guard observations.removeValue(forKey: profileID) != nil else {
            return
        }
        changeSequence &+= 1
    }

    func removeAll() {
        guard !observations.isEmpty else { return }
        observations.removeAll(keepingCapacity: true)
        changeSequence &+= 1
    }
}
