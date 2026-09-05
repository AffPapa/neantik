import Foundation
import Testing
@testable import NeAntik

struct ProfileEditorPresentationTests {
    @Test
    func folderNameValidationExplainsRejectedInputWithoutTruncatingIt() {
        #expect(ProfileFolderNameValidation.message(for: "  Café  ") == nil)
        #expect(ProfileFolderNameValidation.message(for: " \n ") == "Введи название папки.")
        #expect(ProfileFolderNameValidation.message(for: String(repeating: "a", count: 65))?.contains("64") == true)
        #expect(ProfileFolderNameValidation.message(for: "Client\u{202E}A")?.contains("управляющие") == true)
        #expect(ProfileFolderNameValidation.message(for: "Client\nA") != nil)
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 1_100)
        #expect(oversizedGrapheme.count == 1)
        #expect(ProfileFolderNameValidation.message(for: oversizedGrapheme)?.contains("места") == true)
        // Duplicate detection remains separate from structural validation.
        #expect(ProfileFolderNameValidation.message(for: "Cafe") == nil)
        #expect(ProfileFolder.comparisonKey("Cafe") == ProfileFolder.comparisonKey("Café"))
    }

    @Test
    func folderPickerSearchUsesFolderIdentityFolding() {
        let cafe = ProfileFolder(name: "Café"), other = ProfileFolder(name: "Other")
        let found = ProfileFolderPickerPresentation.resolve(folders: [cafe, other], searchText: "  CAFE \n")
        #expect(found.filteredFolders == [cafe])
        #expect(found.returnFolderID == cafe.id)
        let empty = ProfileFolderPickerPresentation.resolve(folders: [cafe, other], searchText: " \n")
        #expect(empty.filteredFolders == [cafe, other])
        #expect(empty.returnFolderID == nil)
        #expect(ProfileFolderPickerPresentation.resolve(folders: [cafe], searchText: "missing").returnFolderID == nil)
    }

    @Test
    func editorHeadingMakesCreateAndEditModesExplicit() {
        let create = ProfileEditorHeadingPresentation.resolve(
            original: nil,
            currentName: "Новый"
        )
        #expect(create.title == "Создание профиля")
        #expect(create.subtitle == nil)

        let profile = BrowserProfile(name: "TikTok · US · 01")
        let edit = ProfileEditorHeadingPresentation.resolve(
            original: profile,
            currentName: profile.name
        )
        #expect(edit.title == "Редактирование профиля")
        #expect(edit.subtitle == profile.name)
        #expect(ProfileEditorAdvancedPresentation.summary.contains("Стартовая"))
    }

    @Test
    func compactFolderControlCoversZeroAndOneFolder() {
        let empty = ProfileEditorFolderPresentation.resolve(
            folders: [],
            selectedFolderID: nil
        )
        #expect(empty.quickOptions.count == 1)
        #expect(empty.selectedTitle == "Без папки")
        #expect(!empty.offersSearchablePicker)

        let folder = ProfileFolder(name: "Работа")
        let single = ProfileEditorFolderPresentation.resolve(
            folders: [folder],
            selectedFolderID: folder.id
        )
        #expect(single.quickOptions.count == 2)
        #expect(single.selectedTitle == "Работа")
        #expect(!single.offersSearchablePicker)
    }

    @Test
    func largeFolderControlStaysBoundedAndKeepsCurrentSelection() {
        let folders = (0..<24).map {
            ProfileFolder(name: "Папка \($0 + 1)")
        }
        let current = folders.last!

        let presentation = ProfileEditorFolderPresentation.resolve(
            folders: folders,
            selectedFolderID: current.id
        )

        #expect(presentation.offersSearchablePicker)
        #expect(
            presentation.quickOptions.count ==
                ProfileFolderCommandProjection.defaultLimit
        )
        #expect(presentation.selectedTitle == current.name)
        #expect(
            presentation.quickOptions.contains(where: {
                $0.folderID == current.id && $0.isSelected
            })
        )
    }

    @Test
    func folderSearchReturnIsExplicitAndDoesNotMoveOnEmptyQuery() {
        let folders = (0..<24).map {
            ProfileFolder(name: "Папка \($0 + 1)")
        }

        let emptyQuery = ProfileFolderPickerPresentation.resolve(
            folders: folders,
            searchText: ""
        )
        #expect(emptyQuery.filteredFolders.count == 24)
        #expect(emptyQuery.returnFolderID == nil)

        let filtered = ProfileFolderPickerPresentation.resolve(
            folders: folders,
            searchText: "Папка 24"
        )
        #expect(filtered.filteredFolders.map(\.name) == ["Папка 24"])
        #expect(filtered.returnFolderID == folders.last?.id)

        let missing = ProfileFolderPickerPresentation.resolve(
            folders: folders,
            searchText: "Нет такой папки"
        )
        #expect(missing.filteredFolders.isEmpty)
        #expect(missing.returnFolderID == nil)
    }

    @Test
    func folderPickerMovesAVisibleKeyboardHighlight() {
        let first = ProfileFolder(name: "Alpha")
        let second = ProfileFolder(name: "Beta")
        let presentation = ProfileFolderPickerPresentation.resolve(
            folders: [first, second],
            searchText: ""
        )

        #expect(
            presentation.movedHighlight(from: .unfiled, offset: 1) ==
                .folder(first.id)
        )
        #expect(
            presentation.movedHighlight(from: .folder(first.id), offset: 1) ==
                .folder(second.id)
        )
        #expect(
            presentation.movedHighlight(from: .folder(second.id), offset: 1) ==
                .folder(second.id)
        )
        #expect(
            !ProfileFolderPickerKeyboardCommitPolicy.permitsCommit(
                searchText: "  ",
                didMoveHighlight: false
            )
        )
        #expect(
            ProfileFolderPickerKeyboardCommitPolicy.permitsCommit(
                searchText: "",
                didMoveHighlight: true
            )
        )
        #expect(
            ProfileFolderPickerKeyboardCommitPolicy.permitsCommit(
                searchText: "Alpha",
                didMoveHighlight: false
            )
        )
    }

    @Test
    func proxyContextUsesTextAndIconForFreshness() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let fresh = ProfileEditorProxyContextPresentation.resolve(
            evidence: .ipAPI(observedAt: now.addingTimeInterval(-60)),
            now: now
        )
        #expect(fresh.title.contains("свежий"))
        #expect(fresh.systemImage == "checkmark.circle.fill")
        #expect(!fresh.requiresAttention)
        #expect(fresh.detail.contains("Перед каждым запуском"))

        let stale = ProfileEditorProxyContextPresentation.resolve(
            evidence: .ipAPI(
                observedAt: now.addingTimeInterval(
                    -ProxyContextEvidence.freshnessLifetime - 1
                )
            ),
            now: now
        )
        #expect(stale.title.contains("устарел"))
        #expect(stale.systemImage == "exclamationmark.triangle.fill")
        #expect(stale.requiresAttention)
        #expect(stale.detail.contains("Перед следующим запуском"))
    }
}

extension ProfileEditorPresentationTests {
    private func state(
        isNew: Bool = false, changes: Bool = false,
        issue: ProfileEditorValidationIssue? = nil,
        proxy: Bool = false, kind: ProxyKind = .http,
        username: Bool = false, testing: Bool = false,
        refreshed: Bool = false, invalidated: Bool = false,
        failed: Bool = false
    ) -> ProfileEditorSavePresentation {
        .resolve(
            isNew: isNew, hasChanges: changes, issue: issue,
            usesProxy: proxy, kind: kind, hasUsername: username,
            isTesting: testing, refreshedEvidence: refreshed,
            invalidatedEvidence: invalidated, latestProbeFailed: failed
        )
    }

    @Test func unchangedEditCannotWriteButNewProfileCanSave() {
        #expect(!state().canSave)
        #expect(state().stateTitle == "Нет изменений")
        #expect(state(isNew: true).canSave)
        #expect(state(changes: true).canSave)
        #expect(state(changes: true).stateTitle.contains("несохранённые"))
    }

    @Test func validationSummaryExplainsWhySaveIsDisabled() {
        let issue = ProfileEditorValidationIssue(field: .name, message: "Введи название профиля.")
        let invalid = state(isNew: true, issue: issue)
        #expect(!invalid.canSave)
        #expect(invalid.stateTitle == issue.message)
    }

    @Test func probeMustFinishOrBeCancelledBeforeSaving() {
        let probing = state(isNew: true, proxy: true, testing: true)
        #expect(!probing.canSave)
        #expect(probing.stateTitle.contains("отмени"))
        #expect(probing.routeSummary.contains("проверяется"))
    }

    @Test func routeSummaryNeverClaimsAnonymityOrPersistsAnEndpoint() {
        #expect(state().routeSummary == "Напрямую · отдельного прокси нет")
        let authenticated = state(proxy: true, username: true)
        #expect(authenticated.routeSummary.contains("Связке ключей"))
        #expect(authenticated.routeSummary.contains("не проверен"))
        #expect(state(proxy: true, kind: .socks5, username: true).routeSummary.contains("без логина"))
    }

    @Test func changedAndFailedProbesOverrideEarlierSuccess() {
        #expect(state(proxy: true, refreshed: true).routeSummary.contains("при запуске повторим"))
        #expect(state(proxy: true, refreshed: true, invalidated: true).routeSummary.contains("проверь снова"))
        #expect(state(proxy: true, refreshed: true, failed: true).routeSummary.contains("не удалась"))
    }

    private func draft(name: String = "Работа", port: String = "8080") -> ProfileEditorDraft {
        ProfileEditorDraft(
            name: name, colorHex: "#123456", symbolName: "folder",
            tags: [], note: "", folderID: nil, startURL: "https://example.com",
            usesProxy: true, proxyKind: .http, proxyHost: "127.0.0.1",
            proxyPort: port, proxyUsername: "", proxyPassword: ""
        )
    }

    @Test func actualDraftEqualityRecognizesRevertedEdits() {
        #expect(draft() == draft())
        #expect(draft() != draft(name: "Другое"))
        #expect(draft() != draft(port: "8081"))
    }

    @Test func overlongNameRemainsAnEditableDraftWithSpecificValidation() {
        let pasted = String(repeating: "я", count: BrowserProfile.maximumNameLength + 1)
        let invalid = draft(name: pasted)
        #expect(invalid.name == pasted)
        #expect(invalid.firstIssue?.field == .name)
        #expect(invalid.firstIssue?.message.contains("120") == true)
        #expect(!state(changes: true, issue: invalid.firstIssue).canSave)
        let corrected = draft(name: String(pasted.dropLast()))
        #expect(corrected.firstIssue == nil)
        #expect(state(changes: true, issue: corrected.firstIssue).canSave)
        let byteHeavy = "a" + String(repeating: "\u{0301}", count: BrowserProfile.maximumNameUTF8Bytes)
        #expect(ProfileEditorValidation.nameMessage(for: byteHeavy)?.contains("места") == true)
        #expect(ProfileEditorValidation.nameMessage(for: "Работа\nАрхив")?.contains("переносы") == true)
        #expect(ProfileEditorValidation.nameMessage(for: "Работа\u{202E}A")?.contains("управляющие") == true)
    }

    @Test func unappliedProxyTextBlocksSavingEvenWhenExistingRouteIsValid() throws {
        let edited = draft(name: "Другое")
        #expect(edited.firstIssue == nil)
        #expect(draft(name: "", port: "0").saveIssue(
            pendingProxyText: "next.example:8080", pendingTagInput: ""
        )?.field == .proxyImport)
        #expect(draft(name: "", port: "0").saveIssue(
            pendingProxyText: " \n ", pendingTagInput: ""
        )?.field == .name)
        for pending in ["next.example:8080", "invalid proxy", "user:secret@next.example:8080"] {
            let issue = try #require(edited.saveIssue(pendingProxyText: pending, pendingTagInput: ""))
            #expect(issue.field == .proxyImport)
            #expect(!issue.message.contains(pending))
            #expect(!state(changes: true, issue: issue, proxy: true).canSave)
            #expect(!state(isNew: true, issue: issue).canSave)
        }
        // A failed parse retains the pending input and thus the Save guard.
        let invalid = "invalid proxy"
        #expect(throws: (any Error).self) {
            try ProxyImportParser.parse(invalid, kind: .http, order: .automatic)
        }
        #expect(ProfileEditorValidation.pendingProxyImportIssue(invalid) != nil)
        // Applying successfully or deliberately clearing the field removes this guard.
        _ = try ProxyImportParser.parse("next.example:8080", kind: .http, order: .automatic)
        for cleared in ["", " \n "] {
            let issue = edited.saveIssue(pendingProxyText: cleared, pendingTagInput: "")
            #expect(issue == nil)
            #expect(state(changes: true, issue: issue, proxy: true).canSave)
        }
    }

    @Test func proxyTestValidationDoesNotRequireProfileName() {
        #expect(draft(name: "").firstIssue?.field == .name)
        #expect(draft(name: "").proxyIssue == nil)
        #expect(draft(port: "0").proxyIssue?.field == .proxyPort)
        #expect(draft(port: "65536").proxyIssue?.field == .proxyPort)
    }
}
