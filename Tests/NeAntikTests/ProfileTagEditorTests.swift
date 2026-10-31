import Foundation
import Testing

@testable import NeAntik

@Suite("ProfileTagEditorTests")
struct ProfileTagEditorTests {
  @Test
  func returnCommitTrimsAndAddsTag() {
    let result = ProfileTagEditorModel.adding(
      "  Работа  ",
      to: ["QA"]
    )

    #expect(result.tags == ["QA", "Работа"])
    #expect(result.remainingInput.isEmpty)
    #expect(result.error == nil)
  }

  @Test
  func commaCommitsCompletedTagsAndKeepsDraft() {
    let result = ProfileTagEditorModel.consumingDelimitedInput(
      "Работа, Клиент,черн",
      tags: []
    )

    #expect(result.tags == ["Работа", "Клиент"])
    #expect(result.remainingInput == "черн")
    #expect(result.error == nil)
  }

  @Test
  func duplicateTagIsConsumedWithoutAddingSecondCopy() {
    let result = ProfileTagEditorModel.adding(
      "cafe",
      to: ["Café"]
    )

    #expect(result.tags == ["Café"])
    #expect(result.remainingInput.isEmpty)
    #expect(result.error == nil)
  }

  @Test
  func maximumCountKeepsRejectedDraftVisible() {
    let tags = (1...BrowserProfile.maximumTagCount).map { "Тег \($0)" }
    let result = ProfileTagEditorModel.adding("Лишний", to: tags)

    #expect(result.tags == tags)
    #expect(result.remainingInput == "Лишний")
    #expect(result.error == .tooMany)
  }

  @Test
  func maximumLengthKeepsRejectedDraftVisible() {
    let tooLong = String(
      repeating: "x",
      count: BrowserProfile.maximumTagLength + 1
    )
    let result = ProfileTagEditorModel.adding(tooLong, to: [])

    #expect(result.tags.isEmpty)
    #expect(result.remainingInput == tooLong)
    #expect(result.error == .tooLong)
  }

  @Test
  func invalidControlCharacterIsRejected() {
    let result = ProfileTagEditorModel.adding("QA\nTeam", to: [])

    #expect(result.tags.isEmpty)
    #expect(result.remainingInput == "QA\nTeam")
    #expect(result.error == .invalid)
  }

  @Test
  func suggestionsAreNormalizedDeduplicatedAndSorted() {
    let suggestions = ProfileTagEditorModel.availableSuggestions(
      [" Shop ", "QA", "shop", "Клиент", ""],
      excluding: ["qa"]
    )

    #expect(Set(suggestions) == Set(["Shop", "Клиент"]))
    #expect(
      suggestions
        == suggestions.sorted {
          $0.localizedStandardCompare($1) == .orderedAscending
        }
    )
  }

  @Test
  func suggestionSearchIsCaseAndDiacriticInsensitive() {
    let suggestions = ["Café", "QA Mobile", "Клиент", "Продажи"]

    #expect(
      ProfileTagEditorModel.filteredSuggestions(
        suggestions,
        matching: " cafe "
      ) == ["Café"]
    )
    #expect(
      ProfileTagEditorModel.filteredSuggestions(
        suggestions,
        matching: "mobile"
      ) == ["QA Mobile"]
    )
    #expect(
      ProfileTagEditorModel.filteredSuggestions(
        suggestions,
        matching: "КЛИ"
      ) == ["Клиент"]
    )
  }

  @Test
  func emptySuggestionSearchKeepsStableSortedOrder() {
    let suggestions = ProfileTagEditorModel.availableSuggestions(
      ["Beta", "Alpha", "Gamma"],
      excluding: []
    )

    #expect(
      ProfileTagEditorModel.filteredSuggestions(
        suggestions,
        matching: "   "
      ) == suggestions
    )
    #expect(ProfileTagEditorModel.searchableSuggestionThreshold == 8)
  }

  @MainActor
  @Test
  func folderAwareInitializerAcceptsOrganizationCompletion() {
    let folder = ProfileFolder(name: "Работа")
    let keychain = KeychainStore(
      backend: ProfileTagEditorKeychainBackend(),
      service: "profile-tag-editor.test",
      legacyService: nil
    )

    let editor = ProfileEditorView(
      original: BrowserProfile(name: "QA", tags: ["qa"]),
      keychain: keychain,
      folders: [folder],
      initialFolderID: folder.id,
      suggestedTags: ["qa", "demo"]
    ) { _, _, _ in }

    #expect(editor.folders == [folder])
    #expect(editor.suggestedTags == ["qa", "demo"])
  }
}

private struct ProfileTagEditorKeychainBackend: KeychainBackend {
  func data(service: String, profileID: UUID) throws -> Data? {
    nil
  }

  func upsert(
    _ data: Data,
    service: String,
    profileID: UUID
  ) throws {}

  func delete(service: String, profileID: UUID) throws {}
}
