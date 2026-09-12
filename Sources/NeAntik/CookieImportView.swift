import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A deliberately local, preview-first cookie import surface. Cookie values
/// stay in view state and are never logged, persisted, or sent to telemetry.
struct CookieImportView: View {
    let profileName: String
    let onImport: ([ImportedCookie]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cookies: [ImportedCookie] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isDropTargeted = false
    @State private var sourceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Импорт cookies")
                .font(.title2.weight(.semibold))
            Text("Профиль: \(profileName)")
                .foregroundStyle(.secondary)

            dropZone

            if isLoading {
                ProgressView("Проверяем файл…")
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !cookies.isEmpty {
                preview
            } else {
                Text("Перетащите JSON или Netscape cookies сюда. Значения будут показаны только для проверки.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Подготовить импорт") {
                    onImport(cookies)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(cookies.isEmpty || isLoading)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .fileImporter(
            isPresented: fileImporterBinding,
            allowedContentTypes: [.json, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                readFile(url, displayName: url.lastPathComponent)
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
    }

    @State private var isFileImporterPresented = false
    private var fileImporterBinding: Binding<Bool> {
        Binding(
            get: { isFileImporterPresented },
            set: { isFileImporterPresented = $0 }
        )
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
            Text("Перетащите файл сюда")
                .font(.headline)
            Button("Выбрать файл…") { isFileImporterPresented = true }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? Color.accentColor : .secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6]))
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL.identifier, UTType.item.identifier, UTType.data.identifier], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            loadDroppedFile(provider)
            return true
        }
        .accessibilityLabel("Область импорта cookies")
        .accessibilityHint("Перетащите JSON или Netscape файл, либо выберите его кнопкой")
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Проверено cookies: \(cookies.count)", systemImage: "checkmark.circle")
                Spacer()
                if let sourceName { Text(sourceName).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Первые записи")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(cookies.prefix(5).enumerated()), id: \.offset) { _, cookie in
                HStack {
                    Text(cookie.name).font(.body.monospaced())
                    Text(cookie.domain).foregroundStyle(.secondary)
                    Spacer()
                    Text(cookie.secure ? "Secure" : "Обычный")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if cookies.count > 5 {
                Text("и ещё \(cookies.count - 5)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func readFile(_ url: URL, displayName: String?) {
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            sourceName = displayName
            defer { isLoading = false }
            do {
                // Finder and the file importer can hand us security-scoped
                // URLs. Keep access scoped to this read, and reject an
                // oversized file before allocating its contents in memory.
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > CookieImportParser.maximumBytes {
                    throw CookieImportError.tooLarge
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                cookies = try CookieImportParser.parse(data)
            } catch {
                cookies = []
                sourceName = nil
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadDroppedFile(_ provider: NSItemProvider) {
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
        }
        let fileType = provider.registeredTypeIdentifiers.first(where: {
            $0 == UTType.fileURL.identifier || $0 == UTType.item.identifier
        })
        if let fileType {
            provider.loadFileRepresentation(forTypeIdentifier: fileType) { url, error in
                if let url {
                    readFile(url, displayName: url.lastPathComponent)
                } else {
                    loadDroppedData(provider, error: error)
                }
            }
        } else {
            loadDroppedData(provider, error: nil)
        }
    }

    private func loadDroppedData(_ provider: NSItemProvider, error: Error?) {
        if let error {
            Task { @MainActor in
                isLoading = false
                errorMessage = error.localizedDescription
            }
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.data.identifier) { data, loadError in
            Task { @MainActor in
                defer { isLoading = false }
                do {
                    guard let data else { throw loadError ?? CookieImportError.malformed }
                    cookies = try CookieImportParser.parse(data)
                    sourceName = "Перетащенный файл"
                } catch {
                    cookies = []
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
