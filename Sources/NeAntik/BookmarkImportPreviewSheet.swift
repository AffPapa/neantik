import SwiftUI

struct BookmarkImportRequest: Identifiable {
    let id = UUID()
    let document: BookmarkImportDocument
}

struct BookmarkImportPreviewSheet: View {
    let document: BookmarkImportDocument
    let isCreating: Bool
    let onCancel: () -> Void
    let onCreate: (String) -> Void
    @State private var name = "Импортированные закладки"
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новый профиль из закладок").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            TextField("Название профиля", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
            Text("Закладок: \(document.linkCount) · папок: \(document.folderCount)").font(.body)
            Text("Будут перенесены только HTTP/HTTPS-закладки и их папки. Новый профиль получит новую identity, прямое подключение и стартовую страницу about:blank.")
            Text("Cookies, пароли, расширения и настройки исходного браузера не импортируются. Профиль не откроется автоматически.").foregroundStyle(.secondary)
            HStack {
                Button("Отмена", action: onCancel).keyboardShortcut(.cancelAction).disabled(isCreating)
                Spacer()
                if isCreating { ProgressView().controlSize(.small) }
                Button(isCreating ? "Создаём…" : "Создать профиль") { onCreate(name) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(isCreating || !BrowserProfile.isValidName(name.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        .padding(24).frame(minWidth: 480, idealWidth: 560, maxWidth: 640)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isCreating)
        .onAppear { nameFocused = true }
    }
}
