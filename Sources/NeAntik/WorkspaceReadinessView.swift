import SwiftUI

struct WorkspaceReadinessView: View {
    let snapshot: WorkspaceReadinessSnapshot
    let applicationPath: String
    let isRefreshing: Bool
    let notice: String?
    let onRecheck: () -> Void
    let onCopyDiagnostics: () -> Void
    let onCopyApplicationPath: () -> Void
    let onRevealApplication: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    permissionGuidance
                    readinessItems
                    privacyBoundary
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 500, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if isRefreshing || snapshot.level == .checking {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: snapshot.level.systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(tint(for: snapshot.level))
                }
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title)
                    .font(.title2.weight(.semibold))
                Text(snapshot.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button {
                onRecheck()
            } label: {
                Label(
                    isRefreshing ? "Проверяем…" : "Проверить снова",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isRefreshing)
            .keyboardShortcut("r", modifiers: [.command])
            .help("Повторить безопасные локальные проверки (⌘R)")
        }
        .padding(20)
        .accessibilityElement(children: .contain)
    }

    private var permissionGuidance: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "macwindow.badge.plus")
                .font(.title3)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Какое приложение добавлять в разрешения macOS")
                    .font(.headline)
                Text(
                    "Выбирай установленный файл NeAntik.app. Не добавляй вложенный NeAntik Browser.app и его Helper-процессы."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(applicationPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button(
                        "Скопировать путь",
                        action: onCopyApplicationPath
                    )
                    Button("Показать в Finder", action: onRevealApplication)
                }
                .controlSize(.small)
                if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        }
        .padding(14)
        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var readinessItems: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.items.enumerated()), id: \.element.id) {
                index, item in
                readinessRow(item)
                if index < snapshot.items.count - 1 {
                    Divider().padding(.leading, 42)
                }
            }
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private func readinessRow(
        _ item: WorkspaceReadinessItem
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.level.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint(for: item.level))
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title).font(.headline)
                    Spacer(minLength: 8)
                    Text(item.level.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint(for: item.level))
                }
                Text(item.value)
                    .font(.subheadline.weight(.medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilitySummary)
    }

    private var privacyBoundary: some View {
        Label {
            Text(
                "Диагностика не содержит пароли, адреса прокси, наблюдаемые IP, зерно отпечатка, хэши или пути отдельных профилей."
            )
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Text("Локальная проверка · без отправки данных")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                onCopyDiagnostics()
            } label: {
                Label("Скопировать диагностику", systemImage: "doc.on.doc")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func tint(
        for level: WorkspaceReadinessLevel
    ) -> Color {
        switch level {
        case .ready: .green
        case .checking: .blue
        case .attention: .orange
        case .blocked: .red
        }
    }
}
