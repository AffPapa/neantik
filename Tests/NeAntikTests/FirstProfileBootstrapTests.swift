import Testing
@testable import NeAntik

struct FirstProfileBootstrapTests {
    @Test
    func emptyWorkspaceCreatesPermanentDirectProfileDefaults() throws {
        let profile = try #require(
            FirstProfileBootstrap.makeProfile(existingProfiles: [])
        )

        #expect(profile.name == "Основной профиль")
        #expect(profile.proxy == nil)
        #expect(profile.startURL == BrowserProfile.defaultStartURL)
        #expect(!profile.isArchived)
        #expect(!profile.isPinned)
        #expect(profile.lastLaunchedAt == nil)
        #expect(BrowserProfile.isValidName(profile.name))
        #expect(FirstProfileBootstrap.routeSummary == "Прямое подключение")
    }

    @Test
    func nonEmptyWorkspaceDoesNotCreateAnotherFirstProfile() {
        let existing = BrowserProfile(name: "Существующий")

        #expect(
            FirstProfileBootstrap.makeProfile(
                existingProfiles: [existing]
            ) == nil
        )
    }

    @Test
    func independentlyCreatedFirstProfilesAreNewIdentityInstances() throws {
        let first = try #require(
            FirstProfileBootstrap.makeProfile(existingProfiles: [])
        )
        let second = try #require(
            FirstProfileBootstrap.makeProfile(existingProfiles: [])
        )

        #expect(first.id != second.id)
        #expect(
            first.identity.issuanceVersion ==
                BrowserIdentityIssuancePolicy.currentVersion
        )
        #expect(
            second.identity.issuanceVersion ==
                BrowserIdentityIssuancePolicy.currentVersion
        )
    }

    @Test
    func quickProfileUsesReadableSequenceAndPermanentDirectDefaults() {
        let profile = QuickProfileBootstrap.makeProfile(
            existingProfiles: [BrowserProfile(name: "Основной профиль")]
        )

        #expect(profile.name == "Профиль 2")
        #expect(profile.proxy == nil)
        #expect(profile.startURL == BrowserProfile.defaultStartURL)
        #expect(profile.lastLaunchedAt == nil)
        #expect(BrowserProfile.isValidName(profile.name))
    }

    @Test
    func quickProfileSkipsCaseInsensitiveNameCollision() {
        let profile = QuickProfileBootstrap.makeProfile(
            existingProfiles: [
                BrowserProfile(name: "Основной профиль"),
                BrowserProfile(name: "пРоФиЛь 3   "),
            ]
        )

        #expect(profile.name == "Профиль 4")
    }

    @Test
    func quickProfilesAlwaysReceiveFreshIdentityAndSession() {
        let existing = [BrowserProfile(name: "Основной профиль")]
        let first = QuickProfileBootstrap.makeProfile(
            existingProfiles: existing
        )
        let second = QuickProfileBootstrap.makeProfile(
            existingProfiles: existing
        )

        #expect(first.id != second.id)
        #expect(first.identity.seed != second.identity.seed)
        #expect(first.note.isEmpty)
    }

    @Test
    func readyRuntimeOffersTheTruthfulCreateAndOpenAction() {
        let presentation = FirstProfileOnboardingPresentation.resolve(
            runtimeAvailability: .ready,
            isCreatingProfile: false
        )

        #expect(presentation.primaryAction == .createAndOpen)
        #expect(presentation.primaryTitle == "Создать и открыть")
        #expect(presentation.primaryIsEnabled)
        #expect(presentation.statusMessage == nil)
        #expect(
            presentation.terminalAccessibilityAnnouncement?
                .contains("готов") == true
        )
    }

    @Test
    func resolvingRuntimeNeverPromisesToOpen() {
        let presentation = FirstProfileOnboardingPresentation.resolve(
            runtimeAvailability: .resolving,
            isCreatingProfile: false
        )

        #expect(presentation.primaryAction == .unavailable)
        #expect(!presentation.primaryIsEnabled)
        #expect(!presentation.primaryTitle.contains("открыть"))
        #expect(presentation.statusMessage?.contains("Проверяем") == true)
        #expect(presentation.terminalAccessibilityAnnouncement == nil)
    }

    @Test(arguments: [
        BrowserRuntimeAvailability.missing,
        BrowserRuntimeAvailability.invalid(message: "Повреждён файл"),
        BrowserRuntimeAvailability.invalid(message: "   "),
    ])
    func unavailableRuntimeOffersRetryWithoutFalseOpenPromise(
        availability: BrowserRuntimeAvailability
    ) {
        let presentation = FirstProfileOnboardingPresentation.resolve(
            runtimeAvailability: availability,
            isCreatingProfile: false
        )

        #expect(presentation.primaryAction == .retryRuntimeCheck)
        #expect(presentation.primaryTitle == "Повторить проверку")
        #expect(presentation.primaryIsEnabled)
        #expect(!presentation.primaryTitle.contains("открыть"))
        #expect(presentation.statusMessage?.isEmpty == false)
        #expect(
            presentation.terminalAccessibilityAnnouncement?
                .contains("Повторная проверка") == true
        )
    }

    @Test(arguments: [
        BrowserRuntimeAvailability.resolving,
        BrowserRuntimeAvailability.ready,
        BrowserRuntimeAvailability.missing,
        BrowserRuntimeAvailability.invalid(message: "Повреждён файл"),
    ])
    func creatingStateIsTerminalAndDisabled(
        availability: BrowserRuntimeAvailability
    ) {
        let presentation = FirstProfileOnboardingPresentation.resolve(
            runtimeAvailability: availability,
            isCreatingProfile: true
        )

        #expect(presentation.primaryAction == .unavailable)
        #expect(!presentation.primaryIsEnabled)
        #expect(presentation.primaryTitle == "Создаём профиль…")
    }
}
