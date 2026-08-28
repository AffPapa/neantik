import Foundation
import Testing
@testable import NeAntik

struct ProfileCommandPresentationTests {
    @Test
    func unavailableCommandsAreDiscoverableButDisabled() {
        let presentation = ProfileCommandPresentation.unavailable

        #expect(presentation.profileName == nil)
        #expect(presentation.launchTitle == "Запустить")
        #expect(!presentation.launchIsEnabled)
        #expect(!presentation.editIsEnabled)
        #expect(!presentation.archiveIsEnabled)
        #expect(!presentation.deleteIsEnabled)
    }

    @Test
    func stoppedProfileSharesLaunchAndOrganizationState() {
        let profile = BrowserProfile(
            name: "Работа",
            isPinned: true
        )
        let launch = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: false,
            runtimeAvailability: .ready
        )

        let presentation = ProfileCommandPresentation.resolve(
            profile: profile,
            processState: .stopped,
            launchAction: launch
        )

        #expect(presentation.profileName == "Работа")
        #expect(presentation.launchTitle == "Запустить")
        #expect(presentation.launchIsEnabled)
        #expect(presentation.editIsEnabled)
        #expect(presentation.pinTitle == "Открепить")
        #expect(presentation.pinSystemImage == "pin.slash")
        #expect(presentation.archiveTitle == "В архив")
        #expect(presentation.archiveIsEnabled)
        #expect(presentation.deleteIsEnabled)
    }

    @Test
    func runningProfileKeepsStopButProtectsMetadataActions() {
        let profile = BrowserProfile(name: "Запущен")
        let launch = BrowserLaunchActionPresentation.resolve(
            processState: .managed,
            isArchived: false,
            runtimeAvailability: .missing
        )

        let presentation = ProfileCommandPresentation.resolve(
            profile: profile,
            processState: .managed,
            launchAction: launch
        )

        #expect(presentation.launchTitle == "Остановить")
        #expect(presentation.launchIsEnabled)
        #expect(!presentation.editIsEnabled)
        #expect(!presentation.archiveIsEnabled)
        #expect(!presentation.deleteIsEnabled)
    }

    @Test
    func archivedProfileUsesReturnCommandAndKeepsEditAvailable() {
        let profile = BrowserProfile(
            name: "Архив",
            isArchived: true
        )
        let launch = BrowserLaunchActionPresentation.resolve(
            processState: .stopped,
            isArchived: true,
            runtimeAvailability: .ready
        )

        let presentation = ProfileCommandPresentation.resolve(
            profile: profile,
            processState: .stopped,
            launchAction: launch
        )

        #expect(presentation.launchTitle == "В архиве")
        #expect(!presentation.launchIsEnabled)
        #expect(presentation.archiveTitle == "Вернуть из архива")
        #expect(presentation.archiveSystemImage == "arrow.uturn.backward")
        #expect(presentation.archiveIsEnabled)
        #expect(presentation.editIsEnabled)
    }

    @Test
    func folderOptionsHaveStableDistinctIdentifiers() {
        let folderID = UUID()
        let options = [
            ProfileFolderCommandOption(
                folderID: nil,
                title: "Без папки",
                isSelected: true
            ),
            ProfileFolderCommandOption(
                folderID: folderID,
                title: "Работа",
                isSelected: false
            ),
        ]

        #expect(options[0].id == "unfiled")
        #expect(options[1].id == folderID.uuidString)
        #expect(Set(options.map { $0.id }).count == options.count)
    }

    @Test
    func folderProjectionStaysBoundedAndKeepsCurrentFolderVisible() {
        let folders = (0..<10_000).map {
            ProfileFolder(name: "Папка \($0)")
        }
        let current = folders.last!

        let projection = ProfileFolderCommandProjection.resolve(
            folders: folders,
            currentFolderID: current.id
        )

        #expect(
            projection.options.count ==
                ProfileFolderCommandProjection.defaultLimit
        )
        #expect(projection.options.first?.folderID == nil)
        #expect(
            projection.options.contains(where: {
                $0.folderID == current.id && $0.isSelected
            })
        )
        #expect(projection.hasMore)
    }

    @Test
    func folderProjectionNeedsNoPickerWhenEveryFolderFits() {
        let folders = [
            ProfileFolder(name: "Личное"),
            ProfileFolder(name: "Работа"),
        ]

        let projection = ProfileFolderCommandProjection.resolve(
            folders: folders,
            currentFolderID: nil
        )

        #expect(projection.options.count == 3)
        #expect(!projection.hasMore)
    }
}
