import Foundation
import Testing

@testable import NeAntik

struct BrowserProcessLifecyclePresentationTests {
    @Test
    func distinguishesManagedRecoveredAndManualOrigins() {
        let profiles = ["Managed", "Recovered", "Manual"].map {
            BrowserProfile(name: $0)
        }
        let states: [UUID: BrowserProfileProcessState] = [
            profiles[0].id: .managed,
            profiles[1].id: .externalVerified,
            profiles[2].id: .externalManualOnly,
        ]
        let items = BrowserProcessLifecycleProjection.resolve(
            profiles: profiles,
            processState: { states[$0] ?? .stopped },
            stopPhase: { _ in .idle },
            startedAt: { _ in Date(timeIntervalSince1970: 0) },
            now: Date(timeIntervalSince1970: 125)
        )

        #expect(items.map(\.origin) == [
            .currentManager, .recoveredManager, .manual,
        ])
        #expect(items[0].detail.contains("2 мин"))
        #expect(items[2].stateTitle == "Запущен вручную")
    }

    @Test func checkingAndRecoveryStatesNeverAppearAsRunning() {
        let profiles = ["Checking", "Recovery", "Unverified"].map {
            BrowserProfile(name: $0)
        }
        let states: [UUID: BrowserProfileProcessState] = [
            profiles[0].id: .checking,
            profiles[1].id: .recoveryRequired,
            profiles[2].id: .externalUnverified,
        ]
        let items = BrowserProcessLifecycleProjection.resolve(
            profiles: profiles,
            processState: { states[$0] ?? .stopped },
            stopPhase: { _ in .idle },
            startedAt: { _ in nil },
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(items.isEmpty)
    }

    @Test
    func closingForceAndCompletedHaveDifferentSafeActions() throws {
        let profile = BrowserProfile(name: "Lifecycle")
        let now = Date(timeIntervalSince1970: 100)
        let phases: [BrowserStopPhase] = [
            .closing(requestedAt: now),
            .forceStopAvailable(requestedAt: now),
            .completed(completedAt: now, wasForced: false),
        ]
        let states: [BrowserProfileProcessState] = [
            .closing, .forceStopAvailable, .stopped,
        ]

        let items = zip(phases, states).map { phase, state in
            BrowserProcessLifecycleProjection.resolve(
                profiles: [profile],
                processState: { _ in state },
                stopPhase: { _ in phase },
                startedAt: { _ in now },
                now: now
            ).first
        }

        #expect(try #require(items[0]).canStop == false)
        #expect(try #require(items[1]).canForceStop)
        #expect(try #require(items[2]).detail.contains("разблокирован"))
        #expect(items.compactMap { $0?.stateTitle }.allSatisfy { !$0.isEmpty })
        #expect(items.compactMap { $0?.detail }.allSatisfy { !$0.isEmpty })
        #expect(Set(items.compactMap { $0?.systemImage }).count == 3)
    }

    @Test
    func elapsedFormattingIsDeterministic() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(BrowserProcessLifecycleProjection.elapsedTitle(
            from: start, to: Date(timeIntervalSince1970: 9)
        ) == "9 с")
        #expect(BrowserProcessLifecycleProjection.elapsedTitle(
            from: start, to: Date(timeIntervalSince1970: 125)
        ) == "2 мин")
        #expect(BrowserProcessLifecycleProjection.elapsedTitle(
            from: start, to: Date(timeIntervalSince1970: 3_900)
        ) == "1 ч 5 мин")
    }
}
