import SwiftUI

struct ProfileFolderNameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialName: String
    let existingNames: [String]
    let onSave: (String) throws -> Void

    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var nameIsFocused: Bool

    init(
        title: String,
        initialName: String = "",
        existingNames: [String],
        onSave: @escaping (String) throws -> Void
    ) {
        self.title = title
        self.initialName = initialName
        self.existingNames = existingNames
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var normalizedName: String? {
        ProfileFolder.normalizedName(name)
    }

    private var duplicatesExistingName: Bool {
        guard let normalizedName else { return false }
        let key = ProfileFolder.comparisonKey(normalizedName)
        let initialKey = ProfileFolder.comparisonKey(initialName)
        return key != initialKey && existingNames.contains {
            ProfileFolder.comparisonKey($0) == key
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Название папки", text: $name)
                .focused($nameIsFocused)
                .onSubmit(save)
                .accessibilityLabel("Название папки")

            Text(
                "До \(ProfileFolder.maximumNameLength) символов. " +
                "Папки нужны только для порядка в NeAntik; " +
                "данные профилей не перемещаются."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if duplicatesExistingName {
                validationLabel(
                    "Папка с таким именем уже существует."
                )
            } else if let errorMessage {
                validationLabel(errorMessage)
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        normalizedName == nil || duplicatesExistingName
                    )
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            nameIsFocused = true
        }
        .onChange(of: name) { _, value in
            if value.count > ProfileFolder.maximumNameLength {
                name = String(value.prefix(ProfileFolder.maximumNameLength))
            }
            errorMessage = nil
        }
        .onChange(of: duplicatesExistingName) { _, isDuplicate in
            guard isDuplicate else { return }
            nameIsFocused = true
        }
    }

    private func save() {
        guard let normalizedName else {
            nameIsFocused = true
            return
        }
        guard !duplicatesExistingName else {
            nameIsFocused = true
            return
        }
        do {
            try onSave(normalizedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            nameIsFocused = true
        }
    }

    private func validationLabel(_ message: String) -> some View {
        Label {
            Text(message)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

}
