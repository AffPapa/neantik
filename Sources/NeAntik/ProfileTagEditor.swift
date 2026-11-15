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
      String(format: NSLocalizedString("userError.186", tableName: "Errors", bundle: .main, value: "Можно добавить не больше %@ тегов.", comment: ""), String(describing: BrowserProfile.maximumTagCount))
    case .tooLong:
      String(format: NSLocalizedString("userError.187", tableName: "Errors", bundle: .main, value: "Тег должен быть не длиннее %@ символов.", comment: ""), String(describing: BrowserProfile.maximumTagLength))
    case .invalid:
      NSLocalizedString("userError.188", tableName: "Errors", bundle: .main, value: "Тег не должен быть пустым или содержать переносы строк.", comment: "")
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
  let suggestions: [String]

  @State private var input = ""
  @State private var suggestionSearch = ""
  @State private var showingSuggestionPicker = false
  @State private var validationMessage: String?
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
          String(format: NSLocalizedString("page.106", tableName: "Pages", bundle: .main, value: "%@ из %@ тегов · до %@ символов", comment: ""), String(describing: tags.count), String(describing: BrowserProfile.maximumTagCount), String(describing: BrowserProfile.maximumTagLength))
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .onChange(of: input) { _, value in
      guard value.contains(",") else {
        validationMessage = nil
        return
      }
      apply(
        ProfileTagEditorModel.consumingDelimitedInput(
          value,
          tags: tags
        )
      )
    }
  }

  private var inputField: some View {
    TextField(
      tags.count >= BrowserProfile.maximumTagCount
        ? NSLocalizedString("page.107", tableName: "Pages", bundle: .main, value: "Достигнут лимит тегов", comment: "")
        : NSLocalizedString("page.108", tableName: "Pages", bundle: .main, value: "Добавить тег", comment: ""),
      text: $input,
      prompt: Text(NSLocalizedString("page.109", tableName: "Pages", bundle: .main, value: "Введи тег и нажми Return", comment: ""))
    )
    .focused($inputIsFocused)
    .onSubmit(commitInput)
    .disabled(tags.count >= BrowserProfile.maximumTagCount)
    .accessibilityLabel(NSLocalizedString("page.110", tableName: "Pages", bundle: .main, value: "Новый тег профиля", comment: ""))
    .accessibilityHint(NSLocalizedString("page.111", tableName: "Pages", bundle: .main, value: "Нажми Return или введи запятую, чтобы добавить тег", comment: ""))
  }

  @ViewBuilder
  private var suggestionMenu: some View {
    if availableSuggestions.count >
      ProfileTagEditorModel.searchableSuggestionThreshold
    {
      Button {
        suggestionSearch = ""
        showingSuggestionPicker = true
      } label: {
        Label(NSLocalizedString("page.112", tableName: "Pages", bundle: .main, value: "Добавить существующий тег", comment: ""), systemImage: "tag")
      }
      .popover(isPresented: $showingSuggestionPicker) {
        searchableSuggestionPicker
      }
      .help(NSLocalizedString("page.113", tableName: "Pages", bundle: .main, value: "Найти и добавить существующий тег", comment: ""))
      .accessibilityLabel(NSLocalizedString("page.114", tableName: "Pages", bundle: .main, value: "Найти существующий тег", comment: ""))
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
        Label(NSLocalizedString("page.112", tableName: "Pages", bundle: .main, value: "Добавить существующий тег", comment: ""), systemImage: "tag")
      }
      .help(NSLocalizedString("page.112", tableName: "Pages", bundle: .main, value: "Добавить существующий тег", comment: ""))
      .accessibilityLabel(NSLocalizedString("page.112", tableName: "Pages", bundle: .main, value: "Добавить существующий тег", comment: ""))
      .disabled(
        availableSuggestions.isEmpty ||
          tags.count >= BrowserProfile.maximumTagCount
      )
    }
  }

  private var searchableSuggestionPicker: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(NSLocalizedString("page.115", tableName: "Pages", bundle: .main, value: "Существующие теги", comment: ""))
        .font(.headline)
        .accessibilityHeading(.h2)

      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField(NSLocalizedString("page.116", tableName: "Pages", bundle: .main, value: "Поиск тегов", comment: ""), text: $suggestionSearch)
          .textFieldStyle(.plain)
          .focused($suggestionSearchIsFocused)
          .accessibilityLabel(NSLocalizedString("page.117", tableName: "Pages", bundle: .main, value: "Поиск существующих тегов", comment: ""))
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
          .help(NSLocalizedString("page.118", tableName: "Pages", bundle: .main, value: "Очистить поиск", comment: ""))
          .accessibilityLabel(NSLocalizedString("page.119", tableName: "Pages", bundle: .main, value: "Очистить поиск тегов", comment: ""))
        }
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 30)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

      if filteredSuggestions.isEmpty {
        ContentUnavailableView(
          NSLocalizedString("page.120", tableName: "Pages", bundle: .main, value: "Теги не найдены", comment: ""),
          systemImage: "tag.slash",
          description: Text(NSLocalizedString("page.121", tableName: "Pages", bundle: .main, value: "Измени запрос или создай новый тег в поле профиля.", comment: ""))
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
              .accessibilityLabel(String(format: NSLocalizedString("page.122", tableName: "Pages", bundle: .main, value: "Добавить тег %@", comment: ""), String(describing: suggestion)))
            }
          }
        }
        .frame(maxHeight: 230)
        .accessibilityLabel(
          String(format: NSLocalizedString("page.123", tableName: "Pages", bundle: .main, value: "Найдено существующих тегов: %@", comment: ""), String(describing: filteredSuggestions.count))
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
      Button {
        remove(tag)
      } label: {
        Image(systemName: "xmark")
          .font(.caption2.weight(.semibold))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(String(format: NSLocalizedString("page.124", tableName: "Pages", bundle: .main, value: "Удалить тег %@", comment: ""), String(describing: tag)))
      .accessibilityLabel(String(format: NSLocalizedString("page.124", tableName: "Pages", bundle: .main, value: "Удалить тег %@", comment: ""), String(describing: tag)))
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
    apply(ProfileTagEditorModel.adding(suggestion, to: tags))
  }

  private func addFirstFilteredSuggestion() {
    guard let suggestion = filteredSuggestions.first else { return }
    addSuggestion(suggestion)
    showingSuggestionPicker = false
  }

  private func remove(_ tag: String) {
    tags.removeAll { $0 == tag }
    validationMessage = nil
    inputIsFocused = true
  }

  private func apply(_ result: ProfileTagEditorInputResult) {
    tags = result.tags
    input = result.remainingInput
    validationMessage = result.error?.localizedDescription
    if result.error != nil {
      inputIsFocused = true
    }
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
      let size = subview.sizeThatFits(.unspecified)
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
      let size = subview.sizeThatFits(.unspecified)
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
