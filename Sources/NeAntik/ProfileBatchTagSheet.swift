import SwiftUI

private enum ProfileBatchTagMode: String, CaseIterable, Identifiable {
    case add
    case remove

    var id: Self { self }

    var title: String {
        switch self {
        case .add: "Добавить"
        case .remove: "Убрать"
        }
    }
}

struct ProfileBatchTagSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profiles: [BrowserProfile]
    let suggestedTags: [String]
    let onApply: (ProfileMetadataBatchAction) throws -> Void

    @State private var mode: ProfileBatchTagMode = .add
    @State private var tag = ""
    @State private var errorMessage: String?
    @FocusState private var tagIsFocused: Bool

    private var cleanTag: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSuggestions: [String] {
        let query = cleanTag
        return ProfileBatchTagPreview.suggestions(
            profiles: profiles, library: suggestedTags, adding: mode == .add
        ).filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }.prefix(8).map { $0 }
    }

    private var canApply: Bool {
        preview.canApply
    }

    private var preview: ProfileBatchTagPreview {
        .resolve(profiles: profiles, tag: cleanTag, adding: mode == .add)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Изменить тег")
                    .font(.headline)
                    .accessibilityHeading(.h1)
                Text("Выбрано профилей: \(profiles.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Picker("Действие", selection: $mode) {
                    ForEach(ProfileBatchTagMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Название тега", text: $tag)
                    .textFieldStyle(.roundedBorder)
                    .focused($tagIsFocused)
                    .onSubmit(apply)

                if !visibleSuggestions.isEmpty {
                    Text("Существующие теги")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(visibleSuggestions, id: \.self) { suggestion in
                                Button(suggestion) { tag = suggestion }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Text(
                    "Изменение применяется ко всем выбранным профилям одной операцией. При ошибке не изменится ни один профиль."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !cleanTag.isEmpty {
                    Text("Тег есть у \(preview.matching) из \(preview.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(preview.message)
                        .font(.caption)
                        .foregroundStyle(preview.blocked > 0 || !preview.valid ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if mode == .remove && visibleSuggestions.isEmpty {
                    Text("У выбранных профилей нет тегов для удаления.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            if let errorMessage {
                UserNoticeLabel(notice: UserNotice(errorMessage, level: .failure))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.title) { apply() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460, height: 440)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                tagIsFocused = true
            }
        }
    }

    private func apply() {
        guard canApply else { return }
        do {
            switch mode {
            case .add:
                try onApply(.addTag(cleanTag))
            case .remove:
                try onApply(.removeTag(cleanTag))
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            tagIsFocused = true
        }
    }
}
