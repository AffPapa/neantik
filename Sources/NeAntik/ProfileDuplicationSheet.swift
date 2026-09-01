import AppKit
import SwiftUI

struct ProfileDuplicationRequest: Identifiable {
    let id = UUID()
    let source: BrowserProfile
    let initialOptions: ProfileDuplicationOptions

    init(
        source: BrowserProfile,
        existingNames: [String],
        destinationFolderID: UUID?
    ) {
        self.source = source
        initialOptions = ProfileDuplicationOptions(
            name: ProfileDuplicationPolicy.suggestedName(
                for: source.name,
                existingNames: existingNames
            ),
            destinationFolderID: destinationFolderID
        )
    }
}

struct ProfileDuplicationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let source: BrowserProfile
    let folders: [ProfileFolder]
    let initialSourceFolderID: UUID?
    let onSave: (ProfileDuplicationOptions) throws -> Void

    @State private var options: ProfileDuplicationOptions
    @State private var errorMessage: String?
    @FocusState private var nameIsFocused: Bool
    @AccessibilityFocusState private var errorIsFocused: Bool

    init(
        source: BrowserProfile,
        folders: [ProfileFolder],
        initialOptions: ProfileDuplicationOptions,
        onSave: @escaping (ProfileDuplicationOptions) throws -> Void
    ) {
        self.source = source
        self.folders = folders
        initialSourceFolderID = initialOptions.destinationFolderID
        self.onSave = onSave
        _options = State(initialValue: initialOptions)
    }

    private var nameValidation: ProfileDuplicationNameValidation {
        ProfileDuplicationNameValidation.resolve(options.name)
    }

    private var destinationTitle: String {
        folders.first(where: { $0.id == options.destinationFolderID })?
            .name ?? "Без папки"
    }

    private var sourceFolderTitle: String {
        folders.first(where: { $0.id == initialSourceFolderID })?
            .name ?? "Без папки"
    }

    private var copiesProxyBinding: Binding<Bool> {
        Binding(
            get: { options.copiesProxy },
            set: { options.setCopiesProxy($0) }
        )
    }

    private var copiesPasswordBinding: Binding<Bool> {
        Binding(
            get: { options.copiesProxyPassword },
            set: { options.setCopiesProxyPassword($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Создать похожий профиль")
                    .font(.headline)
                    .accessibilityHeading(.h1)
                Text("Источник: \(source.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section("Новый профиль") {
                    TextField("Название", text: $options.name)
                        .focused($nameIsFocused)
                        .onSubmit(save)
                        .accessibilityLabel("Название нового профиля")

                    Picker(
                        "Папка назначения",
                        selection: $options.destinationFolderID
                    ) {
                        Text("Без папки").tag(UUID?.none)
                        ForEach(folders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityValue(destinationTitle)

                    Text(
                        options.destinationFolderID == initialSourceFolderID
                            ? "Сохраняем текущую папку: \(sourceFolderTitle)."
                            : "Выбрана другая папка: \(destinationTitle)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Сеть") {
                    Toggle(
                        "Скопировать прокси",
                        isOn: copiesProxyBinding
                    )
                    .disabled(source.proxy == nil)

                    Toggle(
                        "Скопировать пароль прокси из Связки ключей",
                        isOn: copiesPasswordBinding
                    )
                    .disabled(source.proxy == nil || !options.copiesProxy)

                    Text(proxyExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Label(
                        "Всегда создаются новые UUID, BrowserData и цифровая идентичность. Cookies, история и заметка источника не копируются.",
                        systemImage: "shield.checkered"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)

                    if let validationMessage = nameValidation.message {
                        validationLabel(validationMessage)
                    } else if let errorMessage {
                        validationLabel(errorMessage)
                            .accessibilityFocused($errorIsFocused)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 0, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Создать", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!nameValidation.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(
            minWidth: 460,
            idealWidth: 520,
            minHeight: 480,
            idealHeight: 560
        )
        .onAppear { nameIsFocused = true }
        .onChange(of: options.name) { _, _ in
            errorMessage = nil
        }
    }

    private var proxyExplanation: String {
        guard source.proxy != nil else {
            return "Источник использует прямое подключение; копировать нечего."
        }
        guard options.copiesProxy else {
            return "Новый профиль будет использовать прямое подключение."
        }
        if options.copiesProxyPassword {
            return "Прокси и сохранённый пароль будут скопированы только после создания."
        }
        return "Скопируется адрес прокси без пароля."
    }

    @ViewBuilder
    private func validationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
    }

    private func save() {
        guard nameValidation.isValid else {
            nameIsFocused = true
            return
        }
        do {
            try onSave(options)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            errorIsFocused = true
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: error.localizedDescription,
                    .priority:
                        NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }
}
