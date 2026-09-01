import SwiftUI

struct ProfileNoteEditorView: View {
    let profileName: String
    let onSave: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var noteIsFocused: Bool
    @State private var note: String
    @State private var errorMessage: String?

    init(
        profileName: String,
        initialNote: String,
        onSave: @escaping (String) throws -> Void
    ) {
        self.profileName = profileName
        self.onSave = onSave
        _note = State(initialValue: initialNote)
    }

    private var presentation: ProfileNotePresentation {
        ProfileNotePresentation.resolve(note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Заметка профиля")
                    .font(.title2.weight(.semibold))
                Text(profileName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $note)
                    .scrollContentBackground(.hidden)
                    .focused($noteIsFocused)
                    .accessibilityLabel("Заметка профиля \(profileName)")
                    .accessibilityHint(
                        "Сохраняется локально. До \(BrowserProfile.maximumNoteLength) символов."
                    )
                if note.isEmpty {
                    Text("Контекст, статус или следующий шаг")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .frame(minHeight: 150, idealHeight: 190)
            .background(
                .quaternary.opacity(0.35),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(presentation.countLabel)
                    .foregroundStyle(
                        presentation.validationMessage == nil
                            ? Color.secondary
                            : Color.red
                    )
                Spacer()
                if presentation.utf8ByteCount >
                    BrowserProfile.maximumNoteUTF8Bytes
                {
                    Text(
                        "\(presentation.utf8ByteCount) из " +
                            "\(BrowserProfile.maximumNoteUTF8Bytes) байт"
                    )
                    .foregroundStyle(.red)
                }
            }
            .font(.caption)

            if let validationMessage = presentation.validationMessage {
                UserNoticeLabel(
                    notice: UserNotice(
                        validationMessage,
                        level: .failure
                    )
                )
            }

            Label(
                "Заметка хранится локально открытым текстом. Не сохраняй здесь пароли, API-ключи или seed-фразы.",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                UserNoticeLabel(
                    notice: UserNotice(errorMessage, level: .failure)
                )
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(presentation.validationMessage != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 360)
        .onAppear { noteIsFocused = true }
    }

    private func save() {
        guard let normalized = BrowserProfile.normalizedNote(note) else {
            errorMessage = presentation.validationMessage ??
                NeAntikError.invalidProfile.localizedDescription
            return
        }
        do {
            try onSave(normalized)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
