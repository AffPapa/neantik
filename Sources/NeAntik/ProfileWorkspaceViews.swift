import Foundation
import SwiftUI

enum ProfileRowLayout {
    static let minimumWideWidth: CGFloat = 820
    static let spacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 4
    static let actionWidth: CGFloat = 112
    static let minimumIdentityWidth: CGFloat = 180
    static let statusWidth: CGFloat = 105
    static let minimumRouteWidth: CGFloat = 140
    static let minimumContextWidth: CGFloat = 135
    static let menuWidth: CGFloat = 28
}

struct ProfileRow<Actions: View>: View {
    let profile: BrowserProfile
    let processState: BrowserProfileProcessState
    let launchAction: BrowserLaunchActionPresentation
    let proxyHealth: ProxyHealthState?
    let isTestingProxy: Bool
    let folderName: String?
    let usesWideLayout: Bool
    let density: ProfileRowDensity
    let isBatchSelected: Bool
    let onToggleBatchSelection: () -> Void
    let onEditNote: () -> Void
    let onToggleRunning: () -> Void
    let actions: Actions

    init(
        profile: BrowserProfile,
        processState: BrowserProfileProcessState,
        launchAction: BrowserLaunchActionPresentation,
        proxyHealth: ProxyHealthState?,
        isTestingProxy: Bool,
        folderName: String?,
        usesWideLayout: Bool,
        density: ProfileRowDensity = .comfortable,
        isBatchSelected: Bool = false,
        onToggleBatchSelection: @escaping () -> Void = {},
        onEditNote: @escaping () -> Void = {},
        onToggleRunning: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.profile = profile
        self.processState = processState
        self.launchAction = launchAction
        self.proxyHealth = proxyHealth
        self.isTestingProxy = isTestingProxy
        self.folderName = folderName
        self.usesWideLayout = usesWideLayout
        self.density = density
        self.isBatchSelected = isBatchSelected
        self.onToggleBatchSelection = onToggleBatchSelection
        self.onEditNote = onEditNote
        self.onToggleRunning = onToggleRunning
        self.actions = actions()
    }

    var body: some View {
        let presentation = ProfileRowPresentation.resolve(
            profile: profile,
            processState: processState
        )

        Group {
            if usesWideLayout {
                wideRow(presentation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                compactRow(presentation)
            }
        }
        .padding(.vertical, density == .compact ? 3 : 7)
        .frame(minHeight: density == .compact ? 50 : 62)
        .accessibilityElement(children: .contain)
    }

    private func wideRow(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        HStack(spacing: ProfileRowLayout.spacing) {
            HStack(spacing: 6) {
                batchSelectionButton
                launchButton(presentation)
            }
                .frame(width: ProfileRowLayout.actionWidth)
            identityBlock
                .frame(
                    minWidth: ProfileRowLayout.minimumIdentityWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            statusBadge(presentation)
                .frame(
                    width: ProfileRowLayout.statusWidth,
                    alignment: .leading
                )
            routeBlock(presentation)
                .frame(
                    minWidth: ProfileRowLayout.minimumRouteWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            contextBlock(presentation)
                .frame(
                    minWidth: ProfileRowLayout.minimumContextWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            actionsMenu
                .frame(width: ProfileRowLayout.menuWidth)
        }
        .padding(.horizontal, ProfileRowLayout.horizontalPadding)
    }

    private func compactRow(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        HStack(spacing: 10) {
            batchSelectionButton
            launchButton(presentation)
            profileAvatar
            VStack(alignment: .leading, spacing: 4) {
                profileName
                HStack(spacing: 5) {
                    Label(
                        presentation.statusTitle,
                        systemImage: presentation.statusSystemImage
                    )
                    .foregroundStyle(statusColor(for: presentation.statusTone))
                    .layoutPriority(2)
                    .accessibilityLabel(
                        presentation.statusAccessibilityLabel
                    )
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    routeBlock(presentation)
                        .layoutPriority(1)
                }
                .font(.caption)
                .lineLimit(1)

                if !presentation.noteSummary.isEmpty {
                    noteButton(presentation.noteSummary)
                } else if folderName != nil || !profile.tags.isEmpty {
                    organizationMetadata
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    lastLaunchLabel
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)
            actionsMenu
        }
    }

    private var batchSelectionButton: some View {
        Button(action: onToggleBatchSelection) {
            Image(
                systemName:
                    isBatchSelected
                        ? "checkmark.square.fill"
                        : "square"
            )
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isBatchSelected ? Color.accentColor : .secondary)
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            isBatchSelected
                ? "Снять профиль с массовых действий"
                : "Выбрать профиль для массовых действий"
        )
        .accessibilityLabel(
            isBatchSelected
                ? "Снять профиль «\(profile.name)» с массовых действий"
                : "Выбрать профиль «\(profile.name)» для массовых действий"
        )
        .accessibilityValue(isBatchSelected ? "Выбрано" : "Не выбрано")
    }

    private var identityBlock: some View {
        HStack(spacing: 8) {
            profileAvatar
            VStack(alignment: .leading, spacing: 3) {
                profileName
                if folderName != nil || !profile.tags.isEmpty {
                    organizationMetadata
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var profileAvatar: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(hex: profile.colorHex))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: profile.displaySymbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        ProfileAppearance.usesDarkForeground(
                            for: profile.colorHex
                        ) ? Color.black : Color.white
                    )
                if processState.isConfirmedRunning {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            processState.statusTone == .healthy
                                ? Color.green
                                : Color.orange,
                            lineWidth: 2
                        )
                        .padding(-2)
                }
            }
            .accessibilityHidden(true)
    }

    private var profileName: some View {
        HStack(spacing: 5) {
            Text(profile.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .help(profile.name)
                .accessibilityLabel(
                    ProfileRowPresentation.profileAccessibilityLabel(profile)
                )
            if profile.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Закреплён")
            }
        }
    }

    private func statusBadge(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        Label(
            presentation.statusTitle,
            systemImage: presentation.statusSystemImage
        )
        .font(.caption)
        .foregroundStyle(statusColor(for: presentation.statusTone))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            statusColor(for: presentation.statusTone).opacity(0.12),
            in: Capsule()
        )
        .accessibilityLabel(presentation.statusAccessibilityLabel)
    }

    private func routeBlock(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        HStack(spacing: 4) {
            Label(presentation.routeTitle, systemImage: "network")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(presentation.routeTitle)
                .accessibilityLabel(
                    presentation.routeAccessibilityLabel
                )
            routeHealthIndicator
        }
        .font(.caption)
    }

    @ViewBuilder
    private var routeHealthIndicator: some View {
        if !isTestingProxy,
           let attempt = proxyHealth?.latestAttempt
        {
            let routeContextIsComplete =
                proxyHealth?.hasCompleteRouteContext == true
            Image(
                systemName:
                    routeContextIsComplete
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(routeContextIsComplete ? Color.green : .orange)
            .help(
                "Прокси: \(routeContextIsComplete ? attempt.outcome.userSummary : "Маршрут требует повторной подготовки.") \(attempt.checkedAt.neAntikDisplayDateTime)"
            )
            .accessibilityLabel(
                "Проверка прокси: \(routeContextIsComplete ? attempt.outcome.userSummary : "Маршрут требует повторной подготовки.")"
            )
        }
    }

    private func contextBlock(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !presentation.noteSummary.isEmpty {
                noteButton(presentation.noteSummary)
            } else {
                noteButton("")
            }
            lastLaunchLabel
        }
    }

    private var lastLaunchLabel: some View {
        Label(
            profile.lastLaunchedAt.map {
                "Запуск \($0.neAntikDisplayDateTime)"
            } ?? "Не запускался",
            systemImage: "clock"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func noteButton(_ summary: String) -> some View {
        Button(action: onEditNote) {
            Label(
                summary.isEmpty ? "Добавить заметку" : summary,
                systemImage: summary.isEmpty ? "square.and.pencil" : "note.text"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .privacySensitive()
        }
        .buttonStyle(.plain)
        .help(summary.isEmpty ? "Добавить заметку" : "Изменить заметку")
        .accessibilityLabel(
            summary.isEmpty
                ? "Добавить заметку к профилю \(profile.name)"
                : "Изменить заметку профиля \(profile.name)"
        )
        .accessibilityValue(summary.isEmpty ? "Заметки нет" : "Заметка добавлена")
    }

    private func launchButton(
        _ presentation: ProfileRowPresentation
    ) -> some View {
        Button(action: onToggleRunning) {
            if presentation.statusTone == .activity,
               !launchAction.isEnabled
            {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                ViewThatFits(in: .horizontal) {
                    Label(
                        ProfileRowPresentation.compactLaunchTitle(
                            launchAction.title
                        ),
                        systemImage: launchAction.systemImage
                    )
                    Image(systemName: launchAction.systemImage)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(minWidth: 28, minHeight: 28)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(launchTint)
        .disabled(!launchAction.isEnabled)
        .help("\(launchAction.help): «\(profile.name)»")
        .accessibilityLabel("\(launchAction.title) профиль \(profile.name)")
        .layoutPriority(2)
    }

    private var actionsMenu: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Действия с профилем «\(profile.name)»")
        .accessibilityLabel("Действия с профилем \(profile.name)")
    }

    private func statusColor(for tone: BrowserProcessStatusTone) -> Color {
        switch tone {
        case .neutral:
            return .secondary
        case .activity, .attention:
            return .orange
        case .healthy:
            return .green
        }
    }

    private var launchTint: Color {
        processState.statusTone == .healthy ? .red : .green
    }

    private var organizationMetadata: some View {
        HStack(spacing: 5) {
            if let folderName {
                Label(folderName, systemImage: "folder")
                    .lineLimit(1)
                    .help(folderName)
                    .layoutPriority(2)
            }
            if let tag = profile.tags.first {
                ProfileTagChip(
                    tag: tag,
                    horizontalPadding: 5,
                    verticalPadding: 1
                )
            }
            if profile.tags.count > 1 {
                Text("+\(profile.tags.count - 1)")
            }
        }
    }
}

private enum ProfileStorageMeasurementState: Equatable {
    case idle
    case measuring
    case ready(ProfileStorageUsage)
    case failed(String)
}

struct ProfileDetailView: View {
    @State private var technicalDetailsExpanded = false
    @State private var noteExpanded = false
    @State private var storageMeasurement:
        ProfileStorageMeasurementState = .idle
    @State private var storageMeasurementProfileID: UUID?

    let profile: BrowserProfile
    let processState: BrowserProfileProcessState
    let browserDataPath: String
    var folderName: String? = nil
    var environmentSnapshot: ProfileEnvironmentSnapshot? = nil
    var isTestingProxy: Bool = false
    var canCancelProxyTest: Bool = false
    var canRunFingerprintAudit: Bool = false
    let clipboardNotice: String?
    let onCopyProxyUsername: () -> Void
    let onCopyProxyPassword: () -> Void
    var onTestProxy: () -> Void = {}
    var onCancelProxyTest: () -> Void = {}
    var onEditProxy: () -> Void = {}
    var onChangeNote: () -> Void = {}
    var onRunFingerprintAudit: () -> Void = {}

    private var isRunning: Bool {
        processState.isRunning
    }

    private var notePresentation: ProfileNotePresentation {
        ProfileNotePresentation.resolve(profile.note)
    }

    var body: some View {
        VStack(spacing: 0) {
            pinnedHeader
            Divider()

            ScrollView {
                detailContent
                    .frame(maxWidth: 1_160, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: profile.id) { _, _ in
            storageMeasurement = .idle
            storageMeasurementProfileID = nil
        }
    }

    private var pinnedHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            profileIcon
            profileTitle

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            GroupBox("Стартовая страница") {
                LabeledContent("URL", value: profile.startURL)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }

            GroupBox("Профиль") {
                Label(
                    "Cookies, настройки и данные сайтов хранятся отдельно",
                    systemImage: "person.crop.rectangle.stack"
                )
                .padding(.vertical, 4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if profile.note.isEmpty {
                        Text("Не добавлена")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Заметка профиля")
                            .accessibilityValue("Не добавлена")
                    } else {
                        Text(profile.note)
                            .lineLimit(
                                notePresentation.shouldOfferExpansion &&
                                    !noteExpanded
                                    ? 3
                                    : nil
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityLabel("Заметка профиля")
                            .accessibilityValue(profile.note)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            noteActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            noteActions
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Заметка", systemImage: "note.text")
            }

            if profile.proxy != nil {
                GroupBox("Прокси") {
                    networkSummary
                        .padding(.vertical, 4)
                }
            }

            if let environmentSnapshot {
                ProfileEnvironmentView(
                    snapshot: environmentSnapshot,
                    hasProxy: profile.proxy != nil,
                    isTestingProxy: isTestingProxy,
                    canTestProxy: processState == .stopped,
                    canCancelProxyTest: canCancelProxyTest,
                    canRunFingerprintAudit: canRunFingerprintAudit,
                    onTestProxy: onTestProxy,
                    onCancelProxy: onCancelProxyTest,
                    onEditProxy: onEditProxy,
                    onRunFingerprintAudit: onRunFingerprintAudit
                )
                .id(environmentSnapshot.profileID)
            } else if profile.proxy == nil {
                GroupBox("Сеть") {
                    networkSummary
                        .padding(.vertical, 4)
                }
            }

            Button {
                technicalDetailsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: technicalDetailsExpanded
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                    Text("Технические сведения")
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                technicalDetailsExpanded ? "Развёрнуто" : "Свёрнуто"
            )
            .accessibilityHint(
                technicalDetailsExpanded
                    ? "Скрывает локальный путь данных профиля"
                    : "Показывает локальный путь данных профиля"
            )

            if technicalDetailsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Папка данных браузера")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(browserDataPath)
                        .textSelection(.enabled)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Divider()
                        .padding(.vertical, 2)

                    profileStorageMeasurementView
                }
                .padding(.top, 10)
            }

            if let lastLaunchedAt = profile.lastLaunchedAt {
                Text(
                    "Последний запуск: \(lastLaunchedAt.neAntikDisplayDateTime)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileStorageMeasurementView: some View {
        switch storageMeasurement {
        case .idle:
            HStack(spacing: 10) {
                Text("Размер не рассчитывается в фоне")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Рассчитать размер", systemImage: "internaldrive") {
                    measureProfileStorage()
                }
                .controlSize(.small)
            }
        case .measuring:
            Label("Считаем файлы профиля…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .ready(usage):
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(usage.formattedSize)
                        .font(.caption.weight(.semibold))
                    Text("Файлов: \(usage.fileCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Пересчитать", systemImage: "arrow.clockwise") {
                    measureProfileStorage()
                }
                .controlSize(.small)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить", systemImage: "arrow.clockwise") {
                    measureProfileStorage()
                }
                .controlSize(.small)
            }
        }
    }

    private func measureProfileStorage() {
        let requestedProfileID = profile.id
        let directory = URL(fileURLWithPath: browserDataPath)
        storageMeasurementProfileID = requestedProfileID
        storageMeasurement = .measuring
        Task { @MainActor in
            do {
                let usage = try await ProfileStorageMeasurer.measure(
                    at: directory
                )
                guard storageMeasurementProfileID == requestedProfileID else {
                    return
                }
                storageMeasurement = .ready(usage)
            } catch is CancellationError {
                guard storageMeasurementProfileID == requestedProfileID else {
                    return
                }
                storageMeasurement = .idle
            } catch {
                guard storageMeasurementProfileID == requestedProfileID else {
                    return
                }
                storageMeasurement = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var noteActions: some View {
        if notePresentation.shouldOfferExpansion {
            Button(noteExpanded ? "Свернуть" : "Показать полностью") {
                noteExpanded.toggle()
            }
            .frame(minHeight: 28)
            .accessibilityValue(
                noteExpanded ? "Заметка раскрыта" : "Краткий вид"
            )
        }

        Button(action: onChangeNote) {
            Label(
                profile.note.isEmpty
                    ? "Добавить заметку…"
                    : "Изменить заметку…",
                systemImage: profile.note.isEmpty ? "plus" : "pencil"
            )
                .frame(minHeight: 28)
        }
        .help(
            isRunning
                ? "Заметка сохранится сразу; браузер не перезапускается"
                : (
                    profile.note.isEmpty
                        ? "Добавить заметку в редакторе профиля"
                        : "Открыть заметку в редакторе профиля"
                )
        )
    }

    private var networkSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let proxy = profile.proxy {
                LabeledContent("Тип", value: proxy.kind.title)
                LabeledContent("Сервер", value: proxy.displayEndpoint)
                LabeledContent(
                    "Авторизация",
                    value: proxy.username.isEmpty ? "Нет" : "Настроена"
                )
                if !proxy.username.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            credentialButtons
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            credentialButtons
                        }
                    }
                }
                if let clipboardNotice {
                    Label(
                        clipboardNotice,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(clipboardNotice)
                }
            } else {
                LabeledContent("Подключение", value: "Без прокси")
            }
        }
    }

    @ViewBuilder
    private var credentialButtons: some View {
        Button(action: onCopyProxyUsername) {
            Label(
                "Копировать логин",
                systemImage: "person.text.rectangle"
            )
            .frame(minHeight: 28)
        }
        .help("Скопировать логин прокси на 60 секунд")
        .accessibilityHint(
            "Буфер обмена очистится через 60 секунд, если его содержимое не изменится."
        )

        Button(action: onCopyProxyPassword) {
            Label("Копировать пароль", systemImage: "key")
                .frame(minHeight: 28)
        }
        .help("Скопировать пароль из Связки ключей на 60 секунд")
        .accessibilityHint(
            "Буфер обмена очистится через 60 секунд, если его содержимое не изменится."
        )
    }

    private var profileIcon: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(hex: profile.colorHex).gradient)
            .frame(width: 52, height: 52)
            .overlay {
                Image(systemName: profile.displaySymbolName)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(
                        ProfileAppearance.usesDarkForeground(
                            for: profile.colorHex
                        )
                            ? Color.black
                            : Color.white
                    )
            }
            .accessibilityHidden(true)
    }

    private var profileTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Label(
                processState.title,
                systemImage: isRunning ? "circle.fill" : "circle"
            )
            .font(.subheadline)
            .foregroundStyle(processStatusColor)
            if let guidance = processState.guidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(
                        processState.statusTone == .attention
                            ? Color.orange
                            : Color.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !profile.tags.isEmpty {
                Text(profile.tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let folderName {
                Label(folderName, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if profile.isArchived {
                Label("В архиве", systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var processStatusColor: Color {
        switch processState.statusTone {
        case .neutral:
            Color.secondary
        case .activity, .attention:
            Color.orange
        case .healthy:
            Color.green
        }
    }
}
