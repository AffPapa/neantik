import Foundation

extension BrowserProcessManager {
    func lifecycleItems(
        profiles: [BrowserProfile],
        now: Date
    ) -> [BrowserProcessLifecycleItem] {
        BrowserProcessLifecycleProjection.resolve(
            profiles: profiles,
            processState: { processState(for: $0) },
            stopPhase: { stopPhase(for: $0) },
            startedAt: { startedAt(for: $0) },
            now: now
        )
    }

    func requestOrdinaryStop(profileIDs: [UUID]) {
        for profileID in Set(profileIDs) {
            guard processState(for: profileID).canRequestStop,
                  stopPhase(for: profileID) == .idle
            else {
                continue
            }
            stop(profileID: profileID)
        }
    }
}
