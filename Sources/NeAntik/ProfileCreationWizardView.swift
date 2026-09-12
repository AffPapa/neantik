import SwiftUI

/// Purpose-first creation keeps the everyday path to two decisions. Advanced
/// identity, proxy and startup settings remain available after creation.
struct ProfileCreationWizardView: View {
    let targetFolderID: UUID?
    let onCancel: () -> Void
    let onCreate: (BrowserProfile, Bool) throws -> Void
    @State private var name = ""
    @State private var purpose: ProfilePurpose = .work
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новое рабочее место").font(.title3.weight(.semibold))
            Text("Выбери название и назначение. Остальное NeAntik настроит сам.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Название", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Назначение", selection: $purpose) {
                ForEach(ProfilePurpose.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            if let validationMessage { Text(validationMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Отмена", action: onCancel)
                Spacer()
                Button("Создать и открыть") { submit(open: true) }
                    .keyboardShortcut(.defaultAction)
                Button("Создать") { submit(open: false) }
            }
        }
        .padding(24)
        .frame(minWidth: 440)
        .onAppear { if name.isEmpty { name = "Рабочее место" } }
    }

    private func submit(open: Bool) {
        do {
            let profile = try ProfileCreationWizard.makeProfile(
                from: ProfileCreationRequest(name: name, purpose: purpose)
            )
            try onCreate(profile, open)
        } catch { validationMessage = "Проверь название рабочего места." }
    }
}
