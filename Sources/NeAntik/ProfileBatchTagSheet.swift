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

    let profileCount: Int
    let suggestedTags: [String]
    let onApply: (ProfileMetadataBatchAction) -> Void

    @State private var mode: ProfileBatchTagMode = .add
    @State private var tag = ""
    @FocusState private var tagIsFocused: Bool

    private var cleanTag: String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSuggestions: [String] {
        let query = cleanTag
        return suggestedTags.filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }.prefix(8).map { $0 }
    }

    private var canApply: Bool {
        BrowserProfile.normalizedTags([cleanTag])?.first != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Изменить тег")
                    .font(.headline)
                    .accessibilityHeading(.h1)
                Text("Выбрано профилей: \(profileCount)")
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
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

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
        .frame(width: 460, height: 380)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                tagIsFocused = true
            }
        }
    }

    private func apply() {
        guard canApply else { return }
        switch mode {
        case .add:
            onApply(.addTag(cleanTag))
        case .remove:
            onApply(.removeTag(cleanTag))
        }
        dismiss()
    }
}
