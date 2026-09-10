import Testing
@testable import NeAntik

struct RuntimeResolutionStateTests {
    @Test func onlyTheNewestResolutionMayCommit() {
        var state = RuntimeResolutionState()
        let first = state.begin()
        let second = state.begin()

        #expect(!state.isCurrent(first))
        #expect(state.isCurrent(second))
    }
}
