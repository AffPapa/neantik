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
        case .export: NSLocalizedString("page.332", tableName: "Pages", bundle: .main, value: "Зашифровать конфигурацию", comment: "")
        case .import: NSLocalizedString("page.333", tableName: "Pages", bundle: .main, value: "Расшифровать конфигурацию", comment: "")
        }
    }

    var message: String {
        switch self {
        case .export:
            NSLocalizedString("page.334", tableName: "Pages", bundle: .main, value: "Пароль нужен для открытия файла на другом Mac. Он не сохраняется в приложении или файле.", comment: "")
        case .import:
            NSLocalizedString("page.335", tableName: "Pages", bundle: .main, value: "Введи пароль, которым был зашифрован файл конфигурации.", comment: "")
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

            SecureField(NSLocalizedString("page.336", tableName: "Pages", bundle: .main, value: "Пароль, минимум 12 байт UTF-8", comment: ""), text: $passphrase)
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
                SecureField(NSLocalizedString("page.210", tableName: "Pages", bundle: .main, value: "Повтори пароль", comment: ""), text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .confirmation)
                    .onSubmit {
                        if canSubmit { submit() }
                    }
                if !confirmation.isEmpty && passphrase != confirmation {
                    Text(NSLocalizedString("page.337", tableName: "Pages", bundle: .main, value: "Пароли не совпадают.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !passphrase.isEmpty && !hasMinimumLength {
                Text(NSLocalizedString("page.338", tableName: "Pages", bundle: .main, value: "Используй не менее 12 байт UTF-8.", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(NSLocalizedString("page.339", tableName: "Pages", bundle: .main, value: "Отмена", comment: ""), role: .cancel, action: cancel)
                Button(mode == .export ? NSLocalizedString("page.340", tableName: "Pages", bundle: .main, value: "Зашифровать", comment: "") : NSLocalizedString("page.341", tableName: "Pages", bundle: .main, value: "Открыть", comment: "")) {
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
