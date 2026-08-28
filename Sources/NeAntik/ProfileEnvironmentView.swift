import SwiftUI

struct ProfileEnvironmentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedSectionIDs: Set<String> = []
    @State private var hoveredSectionID: String?
    @State private var showingLimitations = false
    @State private var showingDetails = false

    let snapshot: ProfileEnvironmentSnapshot
    let hasProxy: Bool
    let isTestingProxy: Bool
    let canTestProxy: Bool
    let canCancelProxyTest: Bool
    let canRunFingerprintAudit: Bool
    let onTestProxy: () -> Void
    var onCancelProxy: () -> Void = {}
    var onEditProxy: () -> Void = {}
    let onRunFingerprintAudit: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                overview

                Divider()
                    .padding(.vertical, 8)

                Button {
                    showingDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(
                            systemName: showingDetails
                                ? "chevron.down"
                                : "chevron.right"
                        )
                        .font(.caption2.weight(.semibold))
                        Text(
                            showingDetails
                                ? "Скрыть подробности"
                                : "Показать подробности"
                        )
                        Spacer()
                        Text(
                            ProfileEnvironmentPresentation.sectionCountTitle(
                                snapshot.sections.count
                            )
                        )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel(
                                "Диагностических разделов: \(snapshot.sections.count)"
                            )
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    (showingDetails
                        ? "Скрыть подробности"
                        : "Показать подробности") +
                        ", " +
                        ProfileEnvironmentPresentation.sectionCountTitle(
                            snapshot.sections.count
                        )
                )
                .accessibilityValue(
                    showingDetails ? "Развёрнуто" : "Свёрнуто"
                )
                .accessibilityHint(
                    showingDetails
                        ? "Скрывает диагностические разделы"
                        : "Показывает диагностические разделы"
                )

                if showingDetails {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshot.sections) { section in
                            let isExpanded = expandedSectionIDs.contains(
                                section.id
                            )

                            Button {
                                setSectionExpanded(
                                    section.id,
                                    isExpanded: !isExpanded
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Image(
                                        systemName: isExpanded
                                            ? "chevron.down"
                                            : "chevron.right"
                                    )
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)

                                    EnvironmentSectionHeader(section: section)
                                }
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: 32,
                                    alignment: .leading
                                )
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        hoveredSectionID == section.id
                                            ? Color.primary.opacity(0.055)
                                            : Color.clear
                                    )
                            }
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredSectionID = section.id
                                } else if hoveredSectionID == section.id {
                                    hoveredSectionID = nil
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                ProfileEnvironmentPresentation.displayTitle(
                                    for: section
                                ) + ". " +
                                    ProfileEnvironmentPresentation.sectionSummary(
                                        for: section
                                    )
                            )
                            .accessibilityValue(
                                isExpanded ? "Развёрнуто" : "Свёрнуто"
                            )
                            .accessibilityHint(
                                isExpanded
                                    ? "Сворачивает диагностические значения"
                                    : "Раскрывает диагностические значения"
                            )
                            .help(
                                isExpanded
                                    ? "Скрыть значения раздела"
                                    : "Показать значения раздела"
                            )

                            if isExpanded {
                                EnvironmentSectionFields(section: section)
                                    .padding(.leading, 24)
                                    .padding(.bottom, 4)
                            }

                            if section.id != snapshot.sections.last?.id {
                                Divider()
                                    .padding(.leading, 18)
                            }
                        }

                        if hasProxy || canRunFingerprintAudit {
                            Divider()
                                .padding(.top, 6)
                            diagnosticTools
                                .padding(.top, 8)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 6) {
                Label("Среда профиля", systemImage: "checklist.checked")
                    .font(.headline)

                Button {
                    showingLimitations.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Что проверка среды не доказывает")
                .accessibilityLabel("Ограничения проверки среды")
                .popover(isPresented: $showingLimitations) {
                    limitationsPopover
                }
            }
        }
        .onAppear {
            resetExpansion(for: snapshot)
        }
        .onChange(of: snapshot.profileID) { _, _ in
            resetExpansion(for: snapshot)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    overviewFacts
                    if hasOverviewAction {
                        Spacer(minLength: 12)
                        environmentActions
                    }
                }
                .frame(minWidth: 650, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    overviewFacts
                    if hasOverviewAction {
                        environmentActions
                    }
                }
            }

            ForEach(
                ProfileEnvironmentPresentation.criticalFindings(in: snapshot)
            ) { field in
                EnvironmentCriticalFindingSummary(field: field)
            }
        }
    }

    private var overviewFacts: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    EnvironmentOverviewFact(
                        title: "Маршрут",
                        value: ProfileEnvironmentPresentation.routeSummary(
                            in: snapshot
                        )
                    )
                    EnvironmentOverviewFact(
                        title: "Движок",
                        value: ProfileEnvironmentPresentation.runtimeSummary(
                            in: snapshot
                        )
                    )
                }
                .frame(minWidth: 420, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    EnvironmentOverviewFact(
                        title: "Маршрут",
                        value: ProfileEnvironmentPresentation.routeSummary(
                            in: snapshot
                        )
                    )
                    EnvironmentOverviewFact(
                        title: "Движок",
                        value: ProfileEnvironmentPresentation.runtimeSummary(
                            in: snapshot
                        )
                    )
                }
            }

            EnvironmentSeverityRollup(snapshot: snapshot)
        }
    }

    private var recommendedAction: DiagnosticAction? {
        ProfileEnvironmentPresentation.recommendedAction(in: snapshot)
    }

    private var hasOverviewAction: Bool {
        switch recommendedAction {
        case .testProxy:
            hasProxy && (canTestProxy || isTestingProxy)
        case .editProxy:
            hasProxy && canTestProxy
        case .runFingerprintAudit:
            canRunFingerprintAudit
        case .none:
            false
        }
    }

    @ViewBuilder
    private var environmentActions: some View {
        if recommendedAction == .testProxy {
            proxyTestButton
        } else if recommendedAction == .editProxy {
            editProxyButton
        } else if recommendedAction == .runFingerprintAudit {
            fingerprintAuditButton
        }
    }

    private var diagnosticTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Дополнительные проверки")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if hasProxy {
                        proxyTestButton
                    }
                    if canRunFingerprintAudit {
                        fingerprintAuditButton
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    if hasProxy {
                        proxyTestButton
                    }
                    if canRunFingerprintAudit {
                        fingerprintAuditButton
                    }
                }
            }
        }
    }

    private var proxyTestButton: some View {
        Button(
            action:
                isTestingProxy && canCancelProxyTest
                    ? onCancelProxy
                    : onTestProxy
        ) {
            Label(
                isTestingProxy
                    ? (
                        canCancelProxyTest
                            ? "Отменить"
                            : "Проверка в другом окне…"
                    )
                    : "Проверить прокси",
                systemImage: isTestingProxy
                    ? "stop.circle"
                    : "network.badge.shield.half.filled"
            )
        }
        .buttonStyle(.bordered)
        .disabled(
            (isTestingProxy && !canCancelProxyTest) ||
                (!isTestingProxy && !canTestProxy)
        )
        .help(
            isTestingProxy
                ? (
                    canCancelProxyTest
                        ? "Отменить проверку прокси"
                        : "Проверка запущена в другом окне NeAntik"
                )
                : (
                    canTestProxy
                        ? "Проверяет доступность и контекст выхода прокси"
                        : "Сначала останови профиль"
                )
        )
    }

    private var fingerprintAuditButton: some View {
        Button(action: onRunFingerprintAudit) {
            Label("Сравнить отпечатки…", systemImage: "viewfinder")
        }
        .buttonStyle(.bordered)
        .disabled(!canRunFingerprintAudit)
        .help(
            canRunFingerprintAudit
                ? "Локальное сравнение профилей A → B → A"
                : fingerprintDisabledReason
        )
        .accessibilityHint(
            canRunFingerprintAudit
                ? "Запускает локальное сравнение профилей " +
                    "A, B и снова A"
                : fingerprintDisabledReason
        )
    }

    private var editProxyButton: some View {
        Button(action: onEditProxy) {
            Label("Изменить прокси…", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.borderedProminent)
        .help("Исправить адрес, порт, логин или пароль прокси")
        .accessibilityHint(
            "Открывает настройки прокси текущего профиля"
        )
    }

    private var fingerprintDisabledReason: String {
        "Нужны два остановленных активных профиля и " +
            "совместимый браузерный движок"
    }

    private var limitationsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Что проверка не доказывает")
                .font(.headline)
                .accessibilityHeading(.h2)

            ForEach(snapshot.limitations, id: \.self) { item in
                Label(item, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    private func setSectionExpanded(
        _ sectionID: String,
        isExpanded: Bool
    ) {
        let selection = ProfileEnvironmentPresentation.expansionSelection(
            current: expandedSectionIDs,
            sectionID: sectionID,
            isExpanded: isExpanded
        )

        if reduceMotion {
            expandedSectionIDs = selection
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                expandedSectionIDs = selection
            }
        }
    }

    private func resetExpansion(for snapshot: ProfileEnvironmentSnapshot) {
        if let sectionID =
            ProfileEnvironmentPresentation.initialExpandedSectionID(
                in: snapshot
            )
        {
            expandedSectionIDs = [sectionID]
        } else {
            expandedSectionIDs = []
        }
        hoveredSectionID = nil
        showingLimitations = false
        showingDetails = false
    }
}

private struct EnvironmentOverviewFact: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EnvironmentSeverityRollup: View {
    let snapshot: ProfileEnvironmentSnapshot

    private var highestSeverity: DiagnosticFindingSeverity {
        ProfileEnvironmentPresentation.highestSeverity(
            in: snapshot.sections.flatMap(\.fields)
        )
    }

    private var attentionCount: Int {
        ProfileEnvironmentPresentation.attentionCount(in: snapshot)
    }

    private var failureCount: Int {
        ProfileEnvironmentPresentation.failureCount(in: snapshot)
    }

    private var hasAutomaticLaunchFix: Bool {
        ProfileEnvironmentPresentation.hasAutomaticLaunchFix(in: snapshot)
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(
                ProfileEnvironmentPresentation.rollupTitle(
                    highestSeverity: highestSeverity,
                    failureCount: failureCount,
                    attentionCount: attentionCount,
                    hasAutomaticLaunchFix: hasAutomaticLaunchFix
                ),
                systemImage: DiagnosticSeverityPresentation.systemImage(
                    for: highestSeverity
                )
            )
            .foregroundStyle(
                DiagnosticSeverityPresentation.color(for: highestSeverity)
            )

            if attentionCount > 0,
               highestSeverity == .blocking ||
                   highestSeverity == .failure
            {
                Label(
                    ProfileEnvironmentPresentation.attentionTitle(
                        count: attentionCount
                    ),
                    systemImage: "exclamationmark.circle"
                )
                .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .fontWeight(.medium)
        .accessibilityElement(children: .combine)
    }
}

private struct EnvironmentCriticalFindingSummary: View {
    let field: EnvironmentDiagnosticField

    var body: some View {
        Label {
            Text("\(field.title): \(field.value)")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(
                systemName: DiagnosticSeverityPresentation.systemImage(
                    for: field.severity
                )
            )
            .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(
            DiagnosticSeverityPresentation.color(for: field.severity)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(DiagnosticSeverityPresentation.title(for: field.severity)). " +
                "\(field.title): \(field.value)"
        )
    }
}

private struct EnvironmentSectionHeader: View {
    let section: EnvironmentDiagnosticSection

    private var severity: DiagnosticFindingSeverity {
        ProfileEnvironmentPresentation.highestSeverity(in: section.fields)
    }

    private var displayTitle: String {
        ProfileEnvironmentPresentation.displayTitle(for: section)
    }

    private var summary: String {
        ProfileEnvironmentPresentation.sectionSummary(for: section)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                EnvironmentSeverityMark(severity: severity)
            }
            .frame(minWidth: 500, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer(minLength: 6)
                    EnvironmentSeverityMark(severity: severity)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayTitle). \(summary)")
    }
}

private struct EnvironmentSeverityMark: View {
    let severity: DiagnosticFindingSeverity

    var body: some View {
        if severity == .attention ||
            severity == .failure ||
            severity == .blocking
        {
            Image(
                systemName: DiagnosticSeverityPresentation.systemImage(
                    for: severity
                )
            )
            .font(.caption)
            .foregroundStyle(
                DiagnosticSeverityPresentation.color(for: severity)
            )
            .accessibilityHidden(true)
        }
    }
}

private struct EnvironmentSectionFields: View {
    let section: EnvironmentDiagnosticSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(section.fields) { field in
                EnvironmentFieldRow(field: field)

                if field.id != section.fields.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct EnvironmentFieldRow: View {
    let field: EnvironmentDiagnosticField

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideRow
                .frame(minWidth: 620, alignment: .leading)
            compactRow
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var wideRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(field.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            valueAndDetail
                .frame(maxWidth: .infinity, alignment: .leading)

            EnvironmentFieldStatus(field: field)
                .frame(width: 124, alignment: .leading)
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                EnvironmentFieldStatus(field: field)
            }
            valueAndDetail
        }
    }

    private var valueAndDetail: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.value)
                .font(.subheadline)
                .fontWeight(.medium)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = field.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessibilityDescription: String {
        var parts = [
            field.title,
            field.value,
            field.state.title,
            DiagnosticSeverityPresentation.title(for: field.severity),
        ]
        if let detail = field.detail {
            parts.append(detail)
        }
        if let observedAt = field.observedAt {
            parts.append(
                "Измерено " + observedAt.neAntikDisplayDateTime
            )
        }
        return parts.joined(separator: ". ")
    }
}

private struct EnvironmentFieldStatus: View {
    let field: EnvironmentDiagnosticField

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(
                field.state.title,
                systemImage: EvidenceBadgePresentation.systemImage(
                    for: field.state
                )
            )
            .foregroundStyle(.secondary)

            if field.severity != .neutral {
                Label(
                    DiagnosticSeverityPresentation.title(
                        for: field.severity
                    ),
                    systemImage: DiagnosticSeverityPresentation.systemImage(
                        for: field.severity
                    )
                )
                .foregroundStyle(
                    DiagnosticSeverityPresentation.color(
                        for: field.severity
                    )
                )
            }

            if let observedAt = field.observedAt {
                Text(
                    observedAt.neAntikDisplayDateTime
                )
                .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
        .accessibilityHidden(true)
    }
}

enum ProfileEnvironmentPresentation {
    static func sectionCountTitle(_ count: Int) -> String {
        let lastTwo = count % 100
        let noun: String
        if (11...14).contains(lastTwo) {
            noun = "разделов"
        } else {
            switch count % 10 {
            case 1:
                noun = "раздел"
            case 2...4:
                noun = "раздела"
            default:
                noun = "разделов"
            }
        }
        return "\(count) \(noun)"
    }

    static func expansionSelection(
        current: Set<String>,
        sectionID: String,
        isExpanded: Bool
    ) -> Set<String> {
        if isExpanded {
            return [sectionID]
        }

        var updated = current
        updated.remove(sectionID)
        return updated
    }

    static func highestSeverity(
        in fields: [EnvironmentDiagnosticField]
    ) -> DiagnosticFindingSeverity {
        fields.map(\.severity).max {
            severityRank($0) < severityRank($1)
        } ?? .neutral
    }

    static func attentionCount(in snapshot: ProfileEnvironmentSnapshot) -> Int {
        uniqueFindings(snapshot.sections.flatMap(\.fields))
            .filter { $0.severity == .attention }
            .count
    }

    static func failureCount(in snapshot: ProfileEnvironmentSnapshot) -> Int {
        uniqueFindings(snapshot.sections.flatMap(\.fields))
            .filter {
                $0.severity == .failure || $0.severity == .blocking
            }
            .count
    }

    static func criticalFindings(
        in snapshot: ProfileEnvironmentSnapshot
    ) -> [EnvironmentDiagnosticField] {
        uniqueFindings(snapshot.sections.flatMap(\.fields))
            .filter {
                $0.severity == .failure || $0.severity == .blocking
            }
    }

    static func recommendedAction(
        in snapshot: ProfileEnvironmentSnapshot
    ) -> DiagnosticAction? {
        let fields = uniqueFindings(snapshot.sections.flatMap(\.fields))
        for severity in [
            DiagnosticFindingSeverity.blocking,
            .failure,
            .attention,
        ] {
            if let action = fields.first(where: {
                $0.severity == severity &&
                    $0.resolution?.mode == .actionRequired &&
                    $0.resolution?.action != nil
            })?.resolution?.action {
                return action
            }
        }
        return nil
    }

    static func initialExpandedSectionID(
        in snapshot: ProfileEnvironmentSnapshot
    ) -> String? {
        snapshot.sections.first { section in
            section.fields.contains {
                $0.severity == .failure || $0.severity == .blocking
            }
        }?.id
    }

    static func displayTitle(for section: EnvironmentDiagnosticSection) -> String {
        section.id == "fingerprint" ? "Отпечаток браузера" : section.title
    }

    static func sectionSummary(
        for section: EnvironmentDiagnosticSection
    ) -> String {
        let base = baseSummary(for: section)
        let uniqueFields = uniqueFindings(section.fields)
        let blockingCount = uniqueFields.filter {
            $0.severity == .blocking
        }.count
        let failureCount = uniqueFields.filter {
            $0.severity == .failure
        }.count
        let attentionCount = uniqueFields.filter {
            $0.severity == .attention
        }.count

        var parts = [base]
        if blockingCount > 0 {
            parts.append(
                russianCount(
                    blockingCount,
                    one: "блокирует запуск",
                    few: "блокируют запуск",
                    many: "блокируют запуск"
                )
            )
        }
        if failureCount > 0 {
            parts.append(
                russianCount(
                    failureCount,
                    one: "проблема",
                    few: "проблемы",
                    many: "проблем"
                )
            )
        }
        if attentionCount > 0 {
            parts.append(
                russianCount(
                    attentionCount,
                    one: "требует внимания",
                    few: "требуют внимания",
                    many: "требуют внимания"
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    static func routeSummary(in snapshot: ProfileEnvironmentSnapshot) -> String {
        fieldValue(id: "route.mode", in: snapshot) ?? "Не определён"
    }

    static func runtimeSummary(in snapshot: ProfileEnvironmentSnapshot) -> String {
        guard let value = fieldValue(
            id: "fingerprint.runtime",
            in: snapshot
        ) else {
            return "Не найден"
        }
        guard value.localizedCaseInsensitiveContains("Chromium") else {
            return value
        }
        let versionToken = value.split(separator: " ").first {
            $0.first?.isNumber == true
        }
        guard let versionToken,
              let major = versionToken.split(separator: ".").first
        else {
            return "Chromium"
        }
        return "Chromium \(major)"
    }

    static func attentionTitle(count: Int) -> String {
        russianCount(
            count,
            one: "требует внимания",
            few: "требуют внимания",
            many: "требуют внимания"
        )
    }

    static func rollupTitle(
        highestSeverity: DiagnosticFindingSeverity,
        failureCount: Int,
        attentionCount: Int,
        hasAutomaticLaunchFix: Bool = false
    ) -> String {
        switch highestSeverity {
        case .blocking:
            return "Запуск заблокирован"
        case .failure:
            return russianCount(
                failureCount,
                one: "проблема",
                few: "проблемы",
                many: "проблем"
            )
        case .attention:
            return "Нужно проверить"
        case .success:
            return hasAutomaticLaunchFix
                ? "Готово · прокси проверится при запуске"
                : "Среда готова"
        case .neutral:
            return hasAutomaticLaunchFix
                ? "Готово · прокси проверится при запуске"
                : "Среда готова"
        }
    }

    static func hasAutomaticLaunchFix(
        in snapshot: ProfileEnvironmentSnapshot
    ) -> Bool {
        snapshot.sections.flatMap(\.fields).contains {
            $0.resolution?.mode == .fixOnNextLaunch
        }
    }

    private static func baseSummary(
        for section: EnvironmentDiagnosticSection
    ) -> String {
        let preferredFieldIDs: [String]
        switch section.id {
        case "route":
            preferredFieldIDs = ["route.mode"]
        case "fingerprint":
            preferredFieldIDs = [
                "fingerprint.runtime",
                "fingerprint.device-tuple",
            ]
        case "webrtc":
            preferredFieldIDs = ["webrtc.policy"]
        case "transport":
            preferredFieldIDs = [
                "transport.quic-policy",
                "transport.dns-policy",
            ]
        case "geolocation":
            preferredFieldIDs = [
                "geolocation.location",
                "geolocation.context",
                "geolocation.proxy",
                "geolocation.source",
            ]
        default:
            preferredFieldIDs = []
        }

        let values = preferredFieldIDs.compactMap { preferredID in
            section.fields.first { $0.id == preferredID }?.value
        }
        if !values.isEmpty {
            return values.prefix(2).joined(separator: " · ")
        }
        return section.fields.first?.value ?? "Нет данных"
    }

    private static func fieldValue(
        id: String,
        in snapshot: ProfileEnvironmentSnapshot
    ) -> String? {
        snapshot.sections
            .flatMap(\.fields)
            .first { $0.id == id }?
            .value
    }

    private static func uniqueFindings(
        _ fields: [EnvironmentDiagnosticField]
    ) -> [EnvironmentDiagnosticField] {
        var order: [String] = []
        var findingsByKey: [String: EnvironmentDiagnosticField] = [:]
        for field in fields {
            let key = field.resolution.map { "resolution:\($0.key.rawValue)" }
                ?? "field:\(field.id)"
            if let current = findingsByKey[key] {
                if severityRank(field.severity) >
                    severityRank(current.severity)
                {
                    findingsByKey[key] = field
                }
            } else {
                order.append(key)
                findingsByKey[key] = field
            }
        }
        return order.compactMap { findingsByKey[$0] }
    }

    private static func severityRank(
        _ severity: DiagnosticFindingSeverity
    ) -> Int {
        switch severity {
        case .neutral: 0
        case .success: 1
        case .attention: 2
        case .failure: 3
        case .blocking: 4
        }
    }

    private static func russianCount(
        _ count: Int,
        one: String,
        few: String,
        many: String
    ) -> String {
        let remainder100 = count % 100
        let remainder10 = count % 10
        let word: String
        if remainder100 >= 11 && remainder100 <= 14 {
            word = many
        } else if remainder10 == 1 {
            word = one
        } else if remainder10 >= 2 && remainder10 <= 4 {
            word = few
        } else {
            word = many
        }
        return "\(count) \(word)"
    }
}

enum EvidenceBadgePresentation {
    static func systemImage(for state: DiagnosticEvidenceState) -> String {
        switch state {
        case .configured: "slider.horizontal.3"
        case .derived: "equal.circle"
        case .observed: "eye.circle"
        case .unavailable: "minus.circle"
        case .unverified: "questionmark.circle"
        }
    }
}

enum DiagnosticSeverityPresentation {
    static func title(for severity: DiagnosticFindingSeverity) -> String {
        switch severity {
        case .neutral: "Информация"
        case .success: "Подтверждено"
        case .attention: "Требует внимания"
        case .failure: "Проблема"
        case .blocking: "Блокирует запуск"
        }
    }

    static func systemImage(for severity: DiagnosticFindingSeverity) -> String {
        switch severity {
        case .neutral: "info.circle"
        case .success: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .blocking: "hand.raised.circle.fill"
        }
    }

    static func color(for severity: DiagnosticFindingSeverity) -> Color {
        switch severity {
        case .neutral: .secondary
        case .success: .green
        case .attention: .orange
        case .failure, .blocking: .red
        }
    }
}
