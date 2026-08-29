import Testing
@testable import NeAntik

struct ProfileTagAppearanceTests {
    @Test
    func foldedSpellingsAlwaysReceiveTheSameTone() {
        let variants = ["Café", "cafe", "CAFÉ"]
        let tones = variants.map(ProfileTagAppearance.tone(for:))

        #expect(Set(tones).count == 1)
    }

    @Test
    func mappingIsStableAndUsesOnlyNonStatusTones() {
        let first = (0..<100).map {
            ProfileTagAppearance.tone(for: "Тег \($0)")
        }
        let second = (0..<100).map {
            ProfileTagAppearance.tone(for: "Тег \($0)")
        }

        #expect(first == second)
        #expect(Set(first) == Set(ProfileTagTone.allCases))
        #expect(!ProfileTagTone.allCases.map(\.rawValue).contains("red"))
        #expect(!ProfileTagTone.allCases.map(\.rawValue).contains("orange"))
        #expect(!ProfileTagTone.allCases.map(\.rawValue).contains("green"))
    }
}
