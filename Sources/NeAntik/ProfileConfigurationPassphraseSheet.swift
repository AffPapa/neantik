import SwiftUI

enum ProfileConfigurationPassphraseMode: Identifiable, Sendable {
    case export
    case `import`

    var id: String {
        switch self {
        case .export: "export"
        case .import: "import"
        }
    }

    var title: String {
        switch self {
        case .export: "Зашифровать конфигурацию"
        case .import: "Расшифровать конфигурацию"
        }
    }

    var message: String {
        switch self {
        case .export:
            "Пароль нужен для открытия файла на другом Mac. Он не сохраняется в приложении или файле."
        case .import:
            "Введи пароль, которым был зашифрован файл конфигурации."
        }
    }
}

struct ProfileConfigurationPassphraseSheet: View {
    let mode: ProfileConfigurationPassphraseMode
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var passphrase = ""
    @State private var confirmation = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case passphrase
        case confirmation
    }

    private var hasMinimumLength: Bool {
        passphrase.utf8.count >= 12
    }

    private var canSubmit: Bool {
        hasMinimumLength &&
            (mode == .import || passphrase == confirmation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.title)
                .font(.title2.weight(.semibold))

            Text(mode.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Пароль, минимум 12 байт UTF-8", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .passphrase)
                .onSubmit {
                    if mode == .import, canSubmit {
                        submit()
                    } else {
                        focusedField = .confirmation
                    }
                }

            if mode == .export {
                SecureField("Повтори пароль", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .confirmation)
                    .onSubmit {
                        if canSubmit { submit() }
                    }
                if !confirmation.isEmpty && passphrase != confirmation {
                    Text("Пароли не совпадают.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !passphrase.isEmpty && !hasMinimumLength {
                Text("Используй не менее 12 байт UTF-8.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Отмена", role: .cancel, action: cancel)
                Button(mode == .export ? "Зашифровать" : "Открыть") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            focusedField = .passphrase
        }
        .onDisappear {
            clearFields()
        }
        .onExitCommand(perform: cancel)
    }

    private func submit() {
        let value = passphrase
        clearFields()
        onSubmit(value)
    }

    private func cancel() {
        clearFields()
        onCancel()
    }

    private func clearFields() {
        passphrase.removeAll(keepingCapacity: false)
        confirmation.removeAll(keepingCapacity: false)
    }
}
