import AppKit
import SwiftUI

enum ProfileSearchSyntaxHelp {
    static let examples = [
        "тег:tiktok",
        "папка:\"Paid Social\"",
        "прокси:есть",
        "статус:закреплен",
    ]
}

struct ProfileListHeaderView<FiltersMenu: View>: View {
    @Binding var searchText: String
    let searchIsFocused: FocusState<Bool>.Binding
    @Binding var showsSearchHelp: Bool
    @Binding var operationalFilter: ProfileOperationalFilter

    let filtersMenu: FiltersMenu
    let profilesAreEmpty: Bool
    let summary: ProfileOperationalSummary
    let filteredCount: ProfileFilteredCountPresentation
    let bulkProxyAction: BulkProxyActionProjection
    let runtimeIsReady: Bool
    let isCreatingProfileQuickly: Bool
    let bulkProxyTestIsRunning: Bool
    let bulkProxyProgress: BulkProxyRunProgress?
    let bulkProxyStatusMessage: String?
    let hasFailedProxyTests: Bool
    let feedbackNotice: UserNotice?
    let onBulkProxyImport: () -> Void
    let onToggleBulkProxyTests: () -> Void
    let onRetryFailedProxyTests: () -> Void
    let onCreateQuickProfile: () -> Void
    let onCreateConfiguredProfile: () -> Void
    let onFilteredCountChange: (ProfileFilteredCountPresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !profilesAreEmpty {
                ViewThatFits(in: .horizontal) {
                    commandRow
                    commandRow.labelStyle(.iconOnly)
                }
                operationalFilterBar
                filteredCountLabel
            }

            if let feedbackNotice {
                UserNoticeLabel(notice: feedbackNotice)
            }

            bulkProxyStatus
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, WorkspaceLayout.titlebarContentInset)
    }

    private var commandRow: some View {
        HStack(spacing: 8) {
            searchField
            actionsMenu
            filtersMenu
            createProfileMenu
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button(action: onBulkProxyImport) {
                Label(
                    "Создать из списка прокси…",
                    systemImage: "list.bullet.clipboard"
                )
            }
            if !bulkProxyTestIsRunning, bulkProxyAction.isVisible {
                Divider()
                Button(action: onToggleBulkProxyTests) {
                    Label(
                        "Проверить прокси (\(bulkProxyAction.count))",
                        systemImage: "checkmark.shield"
                    )
                }
            }
        } label: {
            Label("Действия", systemImage: "ellipsis.circle")
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Дополнительные действия со списком профилей")
        .accessibilityLabel("Дополнительные действия со списком профилей")
    }

    private var createProfileMenu: some View {
        Menu {
            Button(action: onCreateQuickProfile) {
                Label(
                    "Быстро: создать и открыть без прокси",
                    systemImage: "bolt.fill"
                )
            }
            .disabled(!runtimeIsReady || isCreatingProfileQuickly)

            Divider()

            Button(action: onCreateConfiguredProfile) {
                Label(
                    "Настроить профиль…",
                    systemImage: "slider.horizontal.3"
                )
            }
        } label: {
            Label("Создать профиль", systemImage: "plus")
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 28)
        } primaryAction: {
            onCreateConfiguredProfile()
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .help("Создать профиль (⌘N); стрелка открывает быстрый Direct-вариант")
        .accessibilityLabel(
            "Создать профиль; доступны дополнительные варианты"
        )
    }

    private var operationalFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProfileOperationalFilter.allCases) { filter in
                    operationalFilterButton(filter)
                }
            }
        }
        .accessibilityLabel("Быстрые представления профилей")
    }

    private func operationalFilterButton(
        _ filter: ProfileOperationalFilter
    ) -> some View {
        let isSelected = operationalFilter == filter
        let tint = operationalFilterTint(filter)
        return Button {
            operationalFilter = filter
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.systemImage)
                    .accessibilityHidden(true)
                Text(filter.title)
                Text("\(summary.count(for: filter))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
            }
            .font(.caption.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(
                tint.opacity(isSelected ? 0.18 : 0.07),
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(
                    isSelected ? tint.opacity(0.55) : Color.clear,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title): \(summary.count(for: filter))")
        .accessibilityValue(isSelected ? "Выбрано" : "Не выбрано")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func operationalFilterTint(
        _ filter: ProfileOperationalFilter
    ) -> Color {
        switch filter {
        case .running:
            .green
        case .attention:
            .orange
        case .all, .neverLaunched:
            .accentColor
        }
    }

    private var filteredCountLabel: some View {
        HStack(spacing: 8) {
            Text(filteredCount.title)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(filteredCount.announcement)
            Spacer(minLength: 0)
        }
        .onChange(of: filteredCount) { _, value in
            onFilteredCountChange(value)
        }
    }

    @ViewBuilder
    private var bulkProxyStatus: some View {
        if bulkProxyTestIsRunning {
            Button(action: onToggleBulkProxyTests) {
                Label("Остановить проверку", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .help("Остановить массовую проверку прокси")
            .accessibilityLabel("Остановить массовую проверку прокси")
            if let bulkProxyProgress {
                BulkProxyProgressView(progress: bulkProxyProgress)
            }
        } else if let bulkProxyStatusMessage {
            HStack(spacing: 8) {
                Label(bulkProxyStatusMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if hasFailedProxyTests {
                    Button("Повторить ошибки", action: onRetryFailedProxyTests)
                        .controlSize(.small)
                        .help("Повторить только неуспешные проверки")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Профиль или заметка", text: $searchText)
                .textFieldStyle(.plain)
                .focused(searchIsFocused)
                .accessibilityLabel(
                    "Поиск профилей, маршрутов, заметок, тегов и папок"
                )
                .accessibilityHint(
                    "Можно уточнить запрос: тег, папка, прокси или статус. " +
                        "Название с пробелами заключи в кавычки."
                )
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Очистить поиск")
                .accessibilityLabel("Очистить поиск профилей")
            }
            searchHelpButton
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 180, minHeight: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .help(
            "Примеры: тег:tiktok, папка:\"Paid Social\", " +
                "прокси:есть, статус:закреплен"
        )
        .onExitCommand(perform: exitSearch)
    }

    private var searchHelpButton: some View {
        Button {
            showsSearchHelp.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Синтаксис поиска")
        .accessibilityLabel("Показать синтаксис поиска")
        .popover(isPresented: $showsSearchHelp) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Поиск по полям")
                    .font(.headline)
                    .accessibilityHeading(.h2)
                Text(
                    "Обычный текст ищет по профилю и заметке. " +
                        "Для точного поиска используй:"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(ProfileSearchSyntaxHelp.examples, id: \.self) {
                    Text($0)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                Text("Название с пробелами заключи в кавычки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
    }

    private func exitSearch() {
        if !searchText.isEmpty {
            searchText = ""
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Поиск профилей очищен",
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        } else {
            searchIsFocused.wrappedValue = false
        }
    }
}
