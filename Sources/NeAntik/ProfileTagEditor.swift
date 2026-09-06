import AppKit
import Foundation
import SwiftUI

enum ProfileTagEditorValidationError: LocalizedError, Equatable {
  case tooMany
  case tooLong
  case invalid

  var errorDescription: String? {
    switch self {
    case .tooMany:
      "Можно добавить не больше \(BrowserProfile.maximumTagCount) тегов."
    case .tooLong:
      "Тег должен быть не длиннее \(BrowserProfile.maximumTagLength) символов."
    case .invalid:
      "Тег не должен быть пустым или содержать переносы строк."
    }
  }
}

enum ProfileTagEditorAccessibilityAnnouncement: Equatable {
  case tooMany
  case tooLong
  case invalid

  init(_ error: ProfileTagEditorValidationError) {
    switch error {
    case .tooMany:
      self = .tooMany
    case .tooLong:
      self = .tooLong
    case .invalid:
      self = .invalid
    }
  }

  var message: String {
    switch self {
    case .tooMany:
      "Тег не добавлен. Можно добавить не больше \(BrowserProfile.maximumTagCount) тегов."
    case .tooLong:
      "Тег не добавлен. Сократи тег до \(BrowserProfile.maximumTagLength) символов."
    case .invalid:
      "Тег не добавлен. Удали переносы строк и управляющие символы."
    }
  }
}

struct ProfileTagEditorInputResult: Equatable {
  let tags: [String]
  let remainingInput: String
  let error: ProfileTagEditorValidationError?
}

enum ProfileTagEditorModel {
  static let searchableSuggestionThreshold = 8

  /// Save resolves the final token too; a rejected draft remains intact.
  static func resolvingDraft(
    _ input: String, tags: [String]
  ) -> ProfileTagEditorInputResult {
    let completed = consumingDelimitedInput(input, tags: tags)
    let hasFinalToken = !completed.remainingInput.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).isEmpty
    let result = completed.error == nil && hasFinalToken
      ? adding(completed.remainingInput, to: completed.tags) : completed
    if let error = result.error {
      return .init(tags: tags, remainingInput: input, error: error)
    }
    return .init(tags: result.tags, remainingInput: "", error: nil)
  }

  static func permitsSuggestionCommit(query: String) -> Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func addingSuggestion(
    _ suggestion: String, to tags: [String], preservingInput input: String
  ) -> ProfileTagEditorInputResult {
    let result = adding(suggestion, to: tags)
    return .init(tags: result.tags, remainingInput: input, error: result.error)
  }

  static func adding(
    _ candidate: String,
    to tags: [String]
  ) -> ProfileTagEditorInputResult {
    let clean = candidate.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !clean.isEmpty,
      clean.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      return ProfileTagEditorInputResult(
        tags: tags,
        remainingInput: candidate,
        error: .invalid
      )
    }
    guard clean.count <= BrowserProfile.maximumTagLength else {
      return ProfileTagEditorInputResult(
        tags: tags,
        remainingInput: candidate,
        error: .tooLong
      )
    }
    if tags.contains(where: { comparisonKey($0) == comparisonKey(clean) }) {
      return ProfileTagEditorInputResult(
        tags: tags,
        remainingInput: "",
        error: nil
      )
    }
    guard tags.count < BrowserProfile.maximumTagCount else {
      return ProfileTagEditorInputResult(
        tags: tags,
        remainingInput: candidate,
        error: .tooMany
      )
    }
    guard let normalized = BrowserProfile.normalizedTags(tags + [clean]) else {
      return ProfileTagEditorInputResult(
        tags: tags,
        remainingInput: candidate,
        error: .invalid
      )
    }
    return ProfileTagEditorInputResult(
      tags: normalized,
      remainingInput: "",
      error: nil
    )
  }

  static func consumingDelimitedInput(
    _ input: String,
    tags: [String]
  ) -> ProfileTagEditorInputResult {
    guard input.contains(",") else {
      return ProfileTagEditorInputResult(
        tags: tags,
        remainingInput: input,
        error: nil
      )
    }

    let components = input.split(
      separator: ",",
      omittingEmptySubsequences: false
    ).map(String.init)
    var updatedTags = tags
    let completed = components.dropLast()
    for (index, component) in completed.enumerated() {
      guard
        !component.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty
      else {
        continue
      }
      let result = adding(component, to: updatedTags)
      if let error = result.error {
        let unconsumed =
          Array(completed.dropFirst(index)) + [
            components.last ?? ""
          ]
        return ProfileTagEditorInputResult(
          tags: updatedTags,
          remainingInput: unconsumed.joined(separator: ","),
          error: error
        )
      }
      updatedTags = result.tags
    }
    return ProfileTagEditorInputResult(
      tags: updatedTags,
      remainingInput: components.last ?? "",
      error: nil
    )
  }

  static func availableSuggestions(
    _ suggestions: [String],
    excluding tags: [String]
  ) -> [String] {
    var seen = Set(tags.map(comparisonKey))
    var result: [String] = []
    for suggestion in suggestions {
      guard let normalized = BrowserProfile.normalizedTags([suggestion]),
        let tag = normalized.first,
        seen.insert(comparisonKey(tag)).inserted
      else {
        continue
      }
      result.append(tag)
    }
    return result.sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }

  static func filteredSuggestions(
    _ suggestions: [String],
    matching query: String
  ) -> [String] {
    let cleanQuery = query.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !cleanQuery.isEmpty else { return suggestions }
    let queryKey = comparisonKey(cleanQuery)
    return suggestions.filter {
      comparisonKey($0).contains(queryKey)
    }
  }

  private static func comparisonKey(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }
}

struct ProfileTagEditor: View {
  @Binding var tags: [String]
  @Binding var input: String
  let suggestions: [String]
  var focusRequest = 0

  @State private var suggestionSearch = ""
  @State private var showingSuggestionPicker = false
  @State private var validationMessage: String?
  @State private var announcementGate =
    AccessibilityAnnouncementGate<
      ProfileTagEditorAccessibilityAnnouncement
    >()
  @FocusState private var inputIsFocused: Bool
  @FocusState private var suggestionSearchIsFocused: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  private var availableSuggestions: [String] {
    ProfileTagEditorModel.availableSuggestions(
      suggestions,
      excluding: tags
    )
  }

  private var filteredSuggestions: [String] {
    ProfileTagEditorModel.filteredSuggestions(
      availableSuggestions,
      matching: suggestionSearch
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !tags.isEmpty {
        ProfileTagFlowLayout(spacing: 6) {
          ForEach(tags, id: \.self) { tag in
            tagToken(tag)
          }
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          inputField
            .frame(minWidth: 260)
          suggestionMenu
            .fixedSize()
        }
        VStack(alignment: .leading, spacing: 8) {
          inputField
          suggestionMenu
        }
      }

      if let validationMessage {
        Text(validationMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityLabel(validationMessage)
      } else {
        Text(
          "\(tags.count) из \(BrowserProfile.maximumTagCount) тегов · до \(BrowserProfile.maximumTagLength) символов"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .onChange(of: input) { _, value in
      guard value.contains(",") else {
        validationMessage = nil
        announcementGate.reset()
        return
      }
      apply(
        ProfileTagEditorModel.consumingDelimitedInput(
          value,
          tags: tags
        )
      )
    }
    .onChange(of: focusRequest, initial: true) { _, request in
      if request > 0 { inputIsFocused = true }
    }
  }

  private var inputField: some View {
    TextField(
      tags.count >= BrowserProfile.maximumTagCount
        ? "Достигнут лимит тегов"
        : "Добавить тег",
      text: $input,
      prompt: Text("Введи тег и нажми Return")
    )
    .focused($inputIsFocused)
    .onSubmit(commitInput)
    .disabled(tags.count >= BrowserProfile.maximumTagCount && input.isEmpty)
    .accessibilityLabel("Новый тег профиля")
    .accessibilityHint("Нажми Return или введи запятую, чтобы добавить тег")
  }

  @ViewBuilder
  private var suggestionMenu: some View {
    let availableSuggestions = self.availableSuggestions
    if availableSuggestions.count >
      ProfileTagEditorModel.searchableSuggestionThreshold
    {
      Button {
        suggestionSearch = ""
        showingSuggestionPicker = true
      } label: {
        Label("Добавить существующий тег", systemImage: "tag")
      }
      .popover(isPresented: $showingSuggestionPicker) {
        searchableSuggestionPicker
      }
      .help("Найти и добавить существующий тег")
      .accessibilityLabel("Найти существующий тег")
      .disabled(tags.count >= BrowserProfile.maximumTagCount)
    } else {
      Menu {
        ForEach(availableSuggestions, id: \.self) { suggestion in
          Button {
            addSuggestion(suggestion)
          } label: {
            Label {
              Text(suggestion)
            } icon: {
              Image(systemName: "circle.fill")
                .foregroundStyle(
                  Color(
                    profileTagTone:
                      ProfileTagAppearance.tone(for: suggestion)
                  )
                )
            }
          }
        }
      } label: {
        Label("Добавить существующий тег", systemImage: "tag")
      }
      .help("Добавить существующий тег")
      .accessibilityLabel("Добавить существующий тег")
      .disabled(
        availableSuggestions.isEmpty ||
          tags.count >= BrowserProfile.maximumTagCount
      )
    }
  }

  private var searchableSuggestionPicker: some View {
    let filteredSuggestions = self.filteredSuggestions
    return VStack(alignment: .leading, spacing: 10) {
      Text("Существующие теги")
        .font(.headline)
        .accessibilityHeading(.h2)

      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("Поиск тегов", text: $suggestionSearch)
          .textFieldStyle(.plain)
          .focused($suggestionSearchIsFocused)
          .accessibilityLabel("Поиск существующих тегов")
          .onSubmit(addFirstFilteredSuggestion)
        if !suggestionSearch.isEmpty {
          Button {
            suggestionSearch = ""
            suggestionSearchIsFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Очистить поиск")
          .accessibilityLabel("Очистить поиск тегов")
        }
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 30)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

      if filteredSuggestions.isEmpty {
        ContentUnavailableView(
          "Теги не найдены",
          systemImage: "tag.slash",
          description: Text("Измени запрос или создай новый тег в поле профиля.")
        )
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(filteredSuggestions, id: \.self) { suggestion in
              Button {
                addSuggestion(suggestion)
                showingSuggestionPicker = false
              } label: {
                HStack {
                  ProfileTagMarker(tag: suggestion)
                  Text(suggestion)
                    .lineLimit(1)
                  Spacer(minLength: 12)
                  Image(systemName: "plus")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Добавить тег \(suggestion)")
            }
          }
        }
        .frame(maxHeight: 230)
        .accessibilityLabel(
          "Найдено существующих тегов: \(filteredSuggestions.count)"
        )
      }
    }
    .padding(14)
    .frame(width: 330)
    .onAppear {
      Task { @MainActor in
        await Task.yield()
        suggestionSearchIsFocused = true
      }
    }
    .onDisappear {
      suggestionSearch = ""
      suggestionSearchIsFocused = false
    }
  }

  private func tagToken(_ tag: String) -> some View {
    let color = Color(
      profileTagTone: ProfileTagAppearance.tone(for: tag)
    )
    return HStack(spacing: 2) {
      ProfileTagMarker(tag: tag)
        .padding(.leading, 8)
      Text(tag)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(tag)
      Button {
        remove(tag)
      } label: {
        Image(systemName: "xmark")
          .font(.caption2.weight(.semibold))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .fixedSize()
      .help("Удалить тег \(tag)")
      .accessibilityLabel("Удалить тег \(tag)")
    }
    .frame(minHeight: 28)
    .background(
      color.opacity(contrast == .increased ? 0.24 : 0.14),
      in: Capsule()
    )
    .accessibilityElement(children: .contain)
  }

  private func commitInput() {
    let result = ProfileTagEditorModel.adding(input, to: tags)
    apply(result)
    if result.error == nil {
      inputIsFocused = true
    }
  }

  private func addSuggestion(_ suggestion: String) {
    apply(ProfileTagEditorModel.addingSuggestion(suggestion, to: tags, preservingInput: input))
  }

  private func addFirstFilteredSuggestion() {
    guard ProfileTagEditorModel.permitsSuggestionCommit(query: suggestionSearch) else { return }
    guard let suggestion = filteredSuggestions.first else { return }
    addSuggestion(suggestion)
    showingSuggestionPicker = false
  }

  private func remove(_ tag: String) {
    tags.removeAll { $0 == tag }
    validationMessage = nil
    announcementGate.reset()
    inputIsFocused = true
  }

  private func apply(_ result: ProfileTagEditorInputResult) {
    tags = result.tags
    input = result.remainingInput
    validationMessage = result.error?.localizedDescription
    if let error = result.error {
      inputIsFocused = true
      announce(ProfileTagEditorAccessibilityAnnouncement(error))
    } else {
      announcementGate.reset()
    }
  }

  @MainActor
  private func announce(
    _ announcement: ProfileTagEditorAccessibilityAnnouncement
  ) {
    guard announcementGate.shouldAnnounce(announcement) else { return }
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: announcement.message,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue
      ]
    )
  }
}

private struct ProfileTagFlowLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widestRow: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(
        ProposedViewSize(width: proposal.width, height: nil)
      )
      if currentX > 0, currentX + size.width > maximumWidth {
        widestRow = max(widestRow, currentX - spacing)
        currentX = 0
        currentY += rowHeight + spacing
        rowHeight = 0
      }
      currentX += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    widestRow = max(widestRow, max(0, currentX - spacing))
    let width = proposal.width ?? widestRow
    return CGSize(
      width: width,
      height: subviews.isEmpty ? 0 : currentY + rowHeight
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    var currentX = bounds.minX
    var currentY = bounds.minY
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(
        ProposedViewSize(width: bounds.width, height: nil)
      )
      if currentX > bounds.minX,
        currentX + size.width > bounds.maxX
      {
        currentX = bounds.minX
        currentY += rowHeight + spacing
        rowHeight = 0
      }
      subview.place(
        at: CGPoint(x: currentX, y: currentY),
        anchor: .topLeading,
        proposal: ProposedViewSize(size)
      )
      currentX += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
