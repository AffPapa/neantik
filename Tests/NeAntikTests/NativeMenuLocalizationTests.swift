import Testing
@testable import NeAntik

@MainActor
struct NativeMenuLocalizationTests {
    @Test func englishSelectionLeavesSystemMenuInEnglish() {
        #expect(NativeMenuLocalization.shouldLocalize(preferredLanguage: "ru"))
        #expect(!NativeMenuLocalization.shouldLocalize(preferredLanguage: "en"))
        #expect(!NativeMenuLocalization.shouldLocalize(preferredLanguage: nil))
    }
    @Test func translatesDynamicApplicationCommands() {
        let appName = "NeAntik Dev"
        #expect(
            NativeMenuLocalization.localizedTitle(
                "About NeAntik Dev",
                appName: appName
            ) == "О приложении NeAntik Dev"
        )
        #expect(
            NativeMenuLocalization.localizedTitle(
                "Quit NeAntik Dev",
                appName: appName
            ) == "Завершить NeAntik Dev"
        )
    }

    @Test func translatesPrimaryMacOSMenuTitles() {
        let appName = "NeAntik"
        #expect(
            NativeMenuLocalization.localizedTitle(
                "File",
                appName: appName
            ) == "Файл"
        )
        #expect(
            NativeMenuLocalization.localizedTitle(
                "Hide Others",
                appName: appName
            ) == "Скрыть остальные"
        )
        #expect(
            NativeMenuLocalization.localizedTitle(
                "Unknown System Extension",
                appName: appName
            ) == "Unknown System Extension"
        )
    }
}
