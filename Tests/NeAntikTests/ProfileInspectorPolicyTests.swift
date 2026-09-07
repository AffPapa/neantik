import Testing
@testable import NeAntik

struct ProfileInspectorPolicyTests {
    @Test func openingNeedsSelectionButClosingAlwaysRemainsAvailable() {
        for isPresented in [false, true] {
            for hasSelectedProfile in [false, true] {
                #expect(ProfileInspectorPolicy.canToggle(
                    isPresented: isPresented,
                    hasSelectedProfile: hasSelectedProfile
                ) == (isPresented || hasSelectedProfile))
            }
        }
    }
}
