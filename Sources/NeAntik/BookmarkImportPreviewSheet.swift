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
    @State private var name = NSLocalizedString("page.729", tableName: "Pages", bundle: .main, value: "Импортированные закладки", comment: "")
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("page.730", tableName: "Pages", bundle: .main, value: "Новый профиль из закладок", comment: "")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            TextField(NSLocalizedString("page.731", tableName: "Pages", bundle: .main, value: "Название профиля", comment: ""), text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
            Text(String(format: NSLocalizedString("page.732", tableName: "Pages", bundle: .main, value: "Закладок: %@ · папок: %@", comment: ""), String(describing: document.linkCount), String(describing: document.folderCount))).font(.body)
            Text(NSLocalizedString("page.733", tableName: "Pages", bundle: .main, value: "Будут перенесены только HTTP/HTTPS-закладки и их папки. Новый профиль получит новую identity, прямое подключение и стартовую страницу about:blank.", comment: ""))
            Text(NSLocalizedString("page.734", tableName: "Pages", bundle: .main, value: "Cookies, пароли, расширения и настройки исходного браузера не импортируются. Профиль не откроется автоматически.", comment: "")).foregroundStyle(.secondary)
            HStack {
                Button(NSLocalizedString("page.632", tableName: "Pages", bundle: .main, value: "Отмена", comment: ""), action: onCancel).keyboardShortcut(.cancelAction).disabled(isCreating)
                Spacer()
                if isCreating { ProgressView().controlSize(.small) }
                Button(isCreating ? NSLocalizedString("page.735", tableName: "Pages", bundle: .main, value: "Создаём…", comment: "") : NSLocalizedString("page.736", tableName: "Pages", bundle: .main, value: "Создать профиль", comment: "")) { onCreate(name) }
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
