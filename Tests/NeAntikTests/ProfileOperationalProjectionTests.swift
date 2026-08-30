import Foundation
import Testing
@testable import NeAntik

struct ProfileOperationalProjectionTests {
    @Test
    func derivesSmartViewsWithoutTreatingUncheckedProxyAsBroken() {
        let running = BrowserProfile(
            name: "Running",
            lastLaunchedAt: Date(timeIntervalSince1970: 100)
        )
        let recovery = BrowserProfile(name: "Recovery")
        let failedProxy = BrowserProfile(
            name: "Failed proxy",
            proxy: ProxyConfiguration(
                kind: .https,
                host: "proxy.example",
                port: 8_080,
                username: ""
            )
        )
        let uncheckedProxy = BrowserProfile(
            name: "Unchecked proxy",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "unchecked.example",
                port: 8_081,
                username: ""
            )
        )
        let partialProxy = BrowserProfile(
            name: "Partial proxy context",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "partial.example",
                port: 8_082,
                username: ""
            )
        )
        let profiles = [
            running,
            recovery,
            failedProxy,
            partialProxy,
            uncheckedProxy,
        ]
        let processStates: [UUID: BrowserProfileProcessState] = [
            running.id: .managed,
            recovery.id: .recoveryRequired,
        ]
        let proxyStates: [UUID: ProxyHealthState] = [
            failedProxy.id: ProxyHealthState(
                latestAttempt: ProxyHealthAttempt(
                    checkedAt: Date(timeIntervalSince1970: 200),
                    outcome: .authenticationRejected
                ),
                lastSuccess: nil
            ),
            partialProxy.id: ProxyHealthState(
                latestAttempt: ProxyHealthAttempt(
                    checkedAt: Date(timeIntervalSince1970: 201),
                    outcome: .succeeded
                ),
                lastSuccess: nil
            ),
        ]

        let projection = ProfileOperationalProjection.resolve(
            profiles: profiles,
            processState: { processStates[$0] ?? .stopped },
            proxyHealth: { proxyStates[$0.id] }
        )

        #expect(projection.summary.allCount == 5)
        #expect(projection.summary.runningCount == 1)
        #expect(projection.summary.attentionCount == 3)
        #expect(projection.summary.neverLaunchedCount == 4)
        #expect(projection.profiles(for: .running) == [running])
        #expect(
            projection.profiles(for: .attention) == [
                recovery,
                failedProxy,
                partialProxy,
            ]
        )
        #expect(
            !projection.attentionProfileIDs.contains(uncheckedProxy.id)
        )
    }

    @Test
    func smartViewsPreserveTheIncomingStableOrder() {
        let profiles = (0..<100).map { index in
            BrowserProfile(
                name: String(format: "Profile %03d", index),
                lastLaunchedAt: index.isMultiple(of: 2)
                    ? Date(timeIntervalSince1970: Double(index + 1))
                    : nil
            )
        }
        let runningIDs = Set(profiles.indices.compactMap { index in
            index.isMultiple(of: 3) ? profiles[index].id : nil
        })
        let projection = ProfileOperationalProjection.resolve(
            profiles: profiles,
            processState: {
                runningIDs.contains($0) ? .managed : .stopped
            },
            proxyHealth: { _ in nil }
        )

        #expect(
            projection.profiles(for: .running) == profiles.filter {
                runningIDs.contains($0.id)
            }
        )
        #expect(
            projection.profiles(for: .neverLaunched) == profiles.filter {
                $0.lastLaunchedAt == nil
            }
        )
        #expect(projection.profiles(for: .attention).isEmpty)
    }

    @Test
    func presentationLabelsRemainExplicitAndBounded() {
        #expect(ProfileOperationalFilter.all.title == "Все")
        #expect(ProfileOperationalFilter.running.title == "Запущены")
        #expect(ProfileOperationalFilter.attention.title == "Внимание")
        #expect(
            ProfileOperationalFilter.neverLaunched.title == "Без запусков"
        )
        #expect(ProfileRowDensity.allCases == [.comfortable, .compact])
    }

    @Test
    func tenThousandProfileProjectionStaysLinearAndLocal() {
        let profiles = (0..<10_000).map { index in
            BrowserProfile(
                name: "Profile \(index)",
                identity: BrowserIdentity(seed: UInt32(index + 1)),
                lastLaunchedAt: index.isMultiple(of: 2)
                    ? Date(timeIntervalSince1970: Double(index + 1))
                    : nil
            )
        }
        var processLookupCount = 0
        var proxyLookupCount = 0
        let projection = ProfileOperationalProjection.resolve(
            profiles: profiles,
            processState: {
                processLookupCount += 1
                return $0.uuidString.last?.isNumber == true
                    ? BrowserProfileProcessState.stopped
                    : BrowserProfileProcessState.managed
            },
            proxyHealth: { _ in
                proxyLookupCount += 1
                return nil
            }
        )
        let visibleCount = ProfileOperationalFilter.allCases.reduce(0) {
            $0 + projection.profiles(for: $1).count
        }

        #expect(projection.summary.allCount == 10_000)
        #expect(projection.summary.attentionCount == 0)
        #expect(visibleCount >= 10_000)
        #expect(processLookupCount == 10_000)
        #expect(proxyLookupCount == 10_000)
    }
}
