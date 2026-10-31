import Foundation
import Testing
@testable import NeAntik

struct ManagerSearchBenchmarkTests {
    @Test func metadataSearchPercentiles() {
        for count in [100, 1_000, 5_000] {
            let profiles = (0..<count).map { index in
                BrowserProfile(name: "Synthetic \(index)", tags: ["group-\(index % 10)"])
            }
            let index = ProfileListIndex(profiles: profiles, organization: .empty)
            var samples: [Double] = []
            var paletteSamples: [Double] = []
            for iteration in 0..<55 {
                let start = ContinuousClock.now
                let state = ProfileListViewState(index: index, query: .default,
                    searchText: "Synthetic \(iteration % 10)")
                #expect(!state.visibleProfiles.isEmpty)
                let elapsed = start.duration(to: .now)
                let paletteStart = ContinuousClock.now
                let matches = ProfileQuickCommandProjection.matching(profiles, search: "Synthetic \(iteration % 10)")
                #expect(!matches.isEmpty && matches.count <= 100)
                let paletteElapsed = paletteStart.duration(to: .now)
                if iteration >= 5 {
                    paletteSamples.append(Double(paletteElapsed.components.seconds) * 1000 + Double(paletteElapsed.components.attoseconds) / 1e15)
                    samples.append(Double(elapsed.components.seconds) * 1000 +
                        Double(elapsed.components.attoseconds) / 1e15)
                }
            }
            samples.sort(); paletteSamples.sort()
            print("MANAGER_PALETTE_FILTER debug count=\(count) n=50 p50_ms=\(paletteSamples[24]) p95_ms=\(paletteSamples[47])")
            print("MANAGER_SEARCH debug count=\(count) n=50 p50_ms=\(samples[24]) p95_ms=\(samples[47])")
        }
    }
}
