import AppKit
import SwiftUI

enum ProfileFolderAccessibilityAnnouncement: Equatable {
    case invalidName
    case duplicateName
    case saveFailed

    var message: String {
        switch self {
        case .invalidName:
            "Проверь название папки."
        case .duplicateName:
            "Папка с таким именем уже существует."
        case .saveFailed:
            "Не удалось сохранить папку. Проверь сообщение в окне."
        }
    }
}

struct ProfileFolderNameSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialName: String
    let existingNames: [String]
    let onSave: (String) throws -> Void

    @State private var name: String
    @State private var errorMessage: String?
    @State private var announcementGate =
        AccessibilityAnnouncementGate<ProfileFolderAccessibilityAnnouncement>()
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
                    ProfileFolderAccessibilityAnnouncement.duplicateName.message
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
            if !duplicatesExistingName {
                announcementGate.reset()
            }
        }
        .onChange(of: duplicatesExistingName) { _, isDuplicate in
            guard isDuplicate else { return }
            nameIsFocused = true
            announce(.duplicateName)
        }
    }

    private func save() {
        guard let normalizedName else {
            nameIsFocused = true
            announce(.invalidName)
            return
        }
        guard !duplicatesExistingName else {
            nameIsFocused = true
            announce(.duplicateName)
            return
        }
        do {
            try onSave(normalizedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            nameIsFocused = true
            announcementGate.reset()
            announce(.saveFailed)
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

    @MainActor
    private func announce(
        _ announcement: ProfileFolderAccessibilityAnnouncement
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
