import AppKit
import Foundation
import SwiftUI

struct FingerprintAuditView: View {
    let profiles: [BrowserProfile]
    let runtime: BrowserRuntime
    @ObservedObject var processes: BrowserProcessManager

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator: FingerprintAuditCoordinator
    @State private var firstID: UUID
    @State private var secondID: UUID
    @State private var profileSelectionIsExpanded = false
    @State private var technicalDetailsAreExpanded = false
    @State private var releaseAuditAutoStarted = false
    @State private var releaseAuditTerminationScheduled = false
    private let isReleaseAudit: Bool

    init(
        profiles: [BrowserProfile],
        initialFirstID: UUID?,
        runtime: BrowserRuntime,
        processes: BrowserProcessManager,
        paths: AppPaths,
        releaseContext: FingerprintEvidenceReleaseContext? = nil
    ) {
        self.profiles = profiles
        self.runtime = runtime
        self.processes = processes
        isReleaseAudit = releaseContext != nil

        let first =
            profiles.first(where: { $0.id == initialFirstID }) ??
            profiles.first!
        let second =
            profiles.first(where: { $0.id != first.id }) ??
            first
        _firstID = State(initialValue: first.id)
        _secondID = State(initialValue: second.id)
        _coordinator = StateObject(
            wrappedValue: FingerprintAuditCoordinator(
                paths: paths,
                processes: processes,
                releaseContext: releaseContext
            )
        )
    }

    private var firstProfile: BrowserProfile? {
        profiles.first { $0.id == firstID }
    }

    private var secondProfile: BrowserProfile? {
        profiles.first { $0.id == secondID }
    }

    private var selectedProfileIsRunning: Bool {
        processes.runningProfileIDs.contains(firstID) ||
            processes.runningProfileIDs.contains(secondID)
    }

    private var selectedProfilesAreAvailable: Bool {
        firstProfile != nil && secondProfile != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    profileSelection

                    if coordinator.isRunning {
                        runningState
                    }
                    if let report = coordinator.report {
                        result(report)
                    } else if !coordinator.isRunning {
                        if !isReleaseAudit, selectedProfileIsRunning {
                            runningProfileBlocker
                        } else {
                            explanation
                        }
                    }
                }
                .padding(28)
            }

            Divider()
            controls
        }
        .frame(
            minWidth: 540,
            idealWidth: 680,
            minHeight: 480,
            idealHeight: 660
        )
        .alert(
            isReleaseAudit
                ? "Проверка отпечатка"
                : "Проверка профиля",
            isPresented: Binding(
                get: { coordinator.errorMessage != nil },
                set: { visible in
                    if !visible {
                        coordinator.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                coordinator.errorMessage = nil
            }
        } message: {
            Text(coordinator.errorMessage ?? "Неизвестная ошибка")
        }
        .onDisappear {
            if coordinator.isRunning {
                coordinator.cancel()
            }
        }
        .onAppear {
            normalizeSelection()
            Task { @MainActor in
                startReleaseAuditIfNeeded()
            }
        }
        .onChange(of: profiles.map(\.id)) { _, _ in
            normalizeSelection()
        }
        .onChange(of: coordinator.releaseEvidenceIsReady) { _, ready in
            guard ready,
                  isReleaseAudit,
                  !releaseAuditTerminationScheduled
            else {
                return
            }
            releaseAuditTerminationScheduled = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                NSApplication.shared.terminate(nil)
            }
        }
        .onChange(of: coordinator.errorMessage) { _, message in
            guard isReleaseAudit,
                  let message,
                  !releaseAuditTerminationScheduled
            else {
                return
            }
            releaseAuditTerminationScheduled = true
            if let data = (
                "Автоматическая проверка отпечатка остановлена: " +
                    "\(message)\n"
            ).data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                isReleaseAudit
                    ? "Проверка отпечатка"
                    : "Проверка профиля",
                systemImage:
                    isReleaseAudit
                        ? "waveform.path.ecg.rectangle"
                        : "checkmark.shield"
            )
            .font(.title)
            .fontWeight(.semibold)

            Text(
                isReleaseAudit
                    ? "NeAntik запускает профиль A, профиль B и снова профиль A. Так мы проверяем различие между профилями и стабильность первого профиля без отправки данных на внешний сайт."
                    : "NeAntik проверит, что профиль сохраняет свои параметры и отличается от другого профиля. Данные останутся на этом Mac."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var profileSelection: some View {
        GroupBox(isReleaseAudit ? "Профили" : "Сравниваем профили") {
            VStack(spacing: 12) {
                if isReleaseAudit {
                    profilePickers
                    LabeledContent(
                        "Браузерный движок",
                        value: runtime.runtimeSummary
                    )
                    .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Label(
                            firstProfile.map(profileLabel) ?? "Профиль не найден",
                            systemImage: "person.crop.rectangle"
                        )
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Label(
                            secondProfile.map(profileLabel) ?? "Профиль не найден",
                            systemImage: "person.crop.rectangle"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)

                    DisclosureGroup(
                        "Изменить профили",
                        isExpanded: $profileSelectionIsExpanded
                    ) {
                        profilePickers
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var profilePickers: some View {
        Group {
            Picker("Первый профиль", selection: $firstID) {
                ForEach(profiles) { profile in
                    Text(profileLabel(profile))
                        .tag(profile.id)
                }
            }
            .disabled(coordinator.isRunning)

            Picker("Второй профиль", selection: $secondID) {
                ForEach(profiles) { profile in
                    Text(profileLabel(profile))
                        .tag(profile.id)
                }
            }
            .disabled(coordinator.isRunning)
        }
    }

    private var runningState: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(coordinator.phase)
                    .fontWeight(.medium)
                Text(
                    isReleaseAudit
                        ? "Будет один прямой WebRTC-контроль и три коротких запуска A → B → A. Эти профили должны быть закрыты во время проверки."
                        : "Окна браузера откроются и закроются автоматически. Обычно это занимает меньше минуты."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var explanation: some View {
        if !isReleaseAudit {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Готово к проверке",
                    systemImage: "play.circle.fill"
                )
                .font(.title3)
                .fontWeight(.semibold)
                Text(
                    "Нажми «Проверить». NeAntik сам выполнит сравнение и покажет один понятный результат."
                )
                .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            releaseExplanation
        }
    }

    private var releaseExplanation: some View {
        GroupBox("Что измеряем") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Критичные поверхности: пиксели Canvas и WebGL, звук AudioContext и размеры элементов ClientRects."
                )
                Text(
                    "Контекст: модель графики, расширения, шрифты, экран, процессор, память, язык, часовой пояс, Client Hints и только количество типов WebRTC-кандидатов — без сохранения адресов."
                )
                Text(
                    "Строгая проверка также сравнивает повторные вызовы, CSS media queries и значения основной страницы с Web Worker и OffscreenCanvas."
                )
                Text(
                    "Проверочный скрипт запускается только для этой проверки через локальный DevTools. NeAntik не внедряет его в обычные страницы."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func result(_ report: FingerprintAuditReport) -> some View {
        if isReleaseAudit {
            detailedResult(report)
        } else {
            simpleResult(report)
        }
    }

    private func simpleResult(
        _ report: FingerprintAuditReport
    ) -> some View {
        let passed = report.isPublicAlphaReleaseQualified
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(
                    systemName:
                        passed
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 34))
                .foregroundStyle(passed ? Color.green : Color.orange)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        passed
                            ? "Проверка пройдена"
                            : "Проверка не пройдена"
                    )
                    .font(.title2)
                    .fontWeight(.semibold)
                    Text(
                        passed
                            ? "Профиль стабилен и отличается от другого профиля."
                            : primaryUserIssue(report)
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            DisclosureGroup(
                "Технические подробности",
                isExpanded: $technicalDetailsAreExpanded
            ) {
                detailedResult(report)
                    .padding(.top, 12)
                if let reportURL = coordinator.reportURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            reportURL
                        ])
                    } label: {
                        Label("Показать JSON-отчёт", systemImage: "doc.text")
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func detailedResult(
        _ report: FingerprintAuditReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: verdictIcon(report.verdict))
                    .font(.title2)
                    .foregroundStyle(verdictColor(report.verdict))

                VStack(alignment: .leading, spacing: 4) {
                    Text(report.verdict.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(report.verdict.explanation)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Критичные поверхности") {
                VStack(spacing: 9) {
                    ForEach(
                        FingerprintAuditReport.criticalKeys,
                        id: \.self
                    ) { key in
                        let state = surfaceState(key, report: report)
                        LabeledContent(surfaceTitle(key)) {
                            Label(state.title, systemImage: state.icon)
                                .foregroundStyle(state.color)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Итог") {
                VStack(spacing: 9) {
                    LabeledContent(
                        "Отличающиеся значения",
                        value: "\(report.changedKeys.count)"
                    )
                    LabeledContent(
                        "Нестабильные значения",
                        value: "\(report.unstableKeys.count)"
                    )
                    LabeledContent(
                        "Профиль A",
                        value: firstProfile.map(profileLabel) ??
                            report.firstInitial.profileName
                    )
                    LabeledContent(
                        "Профиль B",
                        value: secondProfile.map(profileLabel) ??
                            report.second.profileName
                    )
                }
                .padding(.vertical, 4)
            }

            GroupBox("Происхождение проверки") {
                VStack(alignment: .leading, spacing: 9) {
                    LabeledContent(
                        "Менеджер",
                        value: report.safeManagerVersionSummary
                    )
                    LabeledContent(
                        "Схема и каталог",
                        value:
                            "\(report.effectiveAuditSchemaVersion) · \(report.identityCatalogVersion.map(String.init) ?? "не записан")"
                    )
                    LabeledContent(
                        "Движок",
                        value: report.safeRuntimeVersionSummary
                    )
                    LabeledContent(
                        "Режим",
                        value: report.effectiveExecutionMode.diagnosticTitle
                    )
                    LabeledContent(
                        "Подпись",
                        value: report.safeRuntimeSignatureSummary
                    )

                    DisclosureGroup("Безопасная диагностическая сводка") {
                        Text(report.safeDiagnosticSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                            .accessibilityLabel(
                                "Безопасная диагностическая сводка проверки"
                            )
                    }
                    .font(.caption)

                    Text(
                        "Текст можно выделить и скопировать. В нём нет имён и идентификаторов профилей, настроек прокси или измеренных значений сайтов."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Доказательство для релиза") {
                VStack(alignment: .leading, spacing: 8) {
                    if report.isPublicAlphaReleaseQualified {
                        Label(
                            "Проверка подходит для публичного теста",
                            systemImage: "checkmark.seal.fill"
                        )
                        .foregroundStyle(.green)
                        if report.isProductionReleaseQualified {
                            Label(
                                "Строгая согласованность production подтверждена",
                                systemImage: "checkmark.shield.fill"
                            )
                            .foregroundStyle(.green)
                        } else {
                            Label(
                                "Строгая согласованность production пока не подтверждена",
                                systemImage: "exclamationmark.shield.fill"
                            )
                            .foregroundStyle(.orange)
                            ForEach(
                                report.productionReleaseIssues,
                                id: \.self
                            ) { issue in
                                Text("• \(localizedIssue(issue))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Label(
                            "Проверка пока не подходит для публичного теста",
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(.orange)
                        ForEach(
                            report.publicAlphaReleaseIssues,
                            id: \.self
                        ) { issue in
                            Text("• \(localizedIssue(issue))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Divider()
                    LabeledContent(
                        "Фактический HTTP-маршрут",
                        value: "Не измерялся"
                    )
                    Text(
                        "Проверка подтверждает настройки запуска и WebRTC-контроль для выбранного маршрута. Она не исключает влияние VPN, сетевого расширения macOS, обязательной политики, DNS-перехвата или расширения, управляющего прокси."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var runningProfileBlocker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(
                "Профиль сейчас открыт",
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.headline)
            Text(
                "Закрой выбранные браузеры, чтобы NeAntik мог проверить их без риска повредить данные."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            let stoppable = [firstID, secondID].filter {
                processes.processState(for: $0).canRequestStop
            }
            if !stoppable.isEmpty {
                Button("Остановить выбранные профили") {
                    for id in stoppable {
                        processes.stop(profileID: id)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func primaryUserIssue(
        _ report: FingerprintAuditReport
    ) -> String {
        guard let issue = report.publicAlphaReleaseIssues.first else {
            return "Проверку не удалось завершить. Закрой другие окна браузера и повтори."
        }
        if issue.contains("unstable") {
            return "Настройки профиля меняются между запусками."
        }
        if issue.contains("WebGL") ||
            issue.contains("separation") ||
            issue.contains("unchanged") {
            return "Профили выглядят слишком похоже."
        }
        if issue.contains("runtime") ||
            issue.contains("code signature") {
            return "Браузерный движок не готов к проверке."
        }
        return localizedIssue(issue)
    }

    private func profileLabel(_ profile: BrowserProfile) -> String {
        let matchingName = profiles.filter { $0.name == profile.name }
        guard matchingName.count > 1,
              let index = profiles.firstIndex(where: { $0.id == profile.id })
        else {
            return profile.name
        }
        return "\(profile.name) · профиль \(index + 1)"
    }

    private func localizedIssue(_ issue: String) -> String {
        if issue.contains("browser mode") ||
            issue.contains("diagnostic mode") {
            return "Отчёт получен не в обычном режиме браузера."
        }
        if issue.contains("strict fingerprint audit schema") {
            return "Нужен свежий отчёт текущего формата; старый отчёт подходит только для уровня public alpha."
        }
        if issue.contains("immutable identity catalog") {
            return "Отчёт не связан с текущей неизменяемой версией каталога устройств."
        }
        if issue.contains("disagrees with worker_") ||
            issue.contains("page and worker") {
            return "Основная страница и Web Worker показывают разные значения."
        }
        if issue.contains("canvas_repeat") {
            return "Повторные чтения Canvas внутри одной страницы нестабильны."
        }
        if issue.contains("client_rects_repeat") {
            return "Повторные чтения ClientRects внутри одной страницы нестабильны."
        }
        if issue.contains("webgl_pixels_repeat") {
            return "Повторные чтения пикселей WebGL внутри одной страницы нестабильны."
        }
        if issue.contains("CSS screen") {
            return "CSS media queries не согласованы с размером экрана и DPR."
        }
        if issue.contains("runtime") {
            return "Отчёт не удалось надёжно связать с проверенным браузерным движком."
        }
        if issue.contains("code signature") {
            return "Не подтверждена подпись браузерного движка."
        }
        if issue.contains("A → B → A") ||
            issue.contains("profile identities") {
            return "Последовательность профилей A → B → A не подтверждена."
        }
        if issue.contains("unavailable") {
            return "Часть обязательных поверхностей браузера недоступна."
        }
        if issue.contains("unstable") {
            return "Значения профиля A изменились при повторном запуске."
        }
        if issue.contains("WebGL") {
            return "Пиксели WebGL не различаются между профилями."
        }
        return "Одна из обязательных технических проверок не пройдена; подробности сохранены в JSON-отчёте."
    }

    private var controls: some View {
        HStack {
            if isReleaseAudit, let reportURL = coordinator.reportURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        reportURL
                    ])
                } label: {
                    Label("Показать отчёт", systemImage: "doc.text")
                }
            }

            Spacer()

            if coordinator.isRunning {
                Button("Остановить проверку", role: .destructive) {
                    coordinator.cancel()
                }
            } else {
                Button("Закрыть") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(
                    isReleaseAudit
                        ? "Запустить A → B → A"
                        : (
                            coordinator.report == nil
                                ? "Проверить"
                                : "Проверить снова"
                        )
                ) {
                    startSelectedAudit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !selectedProfilesAreAvailable ||
                        firstID == secondID ||
                        selectedProfileIsRunning
                )
            }
        }
        .padding()
    }

    private func normalizeSelection() {
        guard !profiles.isEmpty else { return }
        if !profiles.contains(where: { $0.id == firstID }) {
            firstID = profiles[0].id
        }
        if !profiles.contains(where: { $0.id == secondID }) ||
            secondID == firstID {
            secondID = profiles.first(where: { $0.id != firstID })?.id ??
                firstID
        }
    }

    private func startReleaseAuditIfNeeded() {
        guard isReleaseAudit,
              !releaseAuditAutoStarted,
              !coordinator.isRunning,
              coordinator.report == nil,
              coordinator.errorMessage == nil,
              selectedProfilesAreAvailable,
              firstID != secondID,
              !selectedProfileIsRunning
        else {
            return
        }
        releaseAuditAutoStarted = true
        startSelectedAudit()
    }

    private func startSelectedAudit() {
        guard let firstProfile, let secondProfile else {
            coordinator.errorMessage =
                "Выбранный профиль больше не найден в списке. Закрой окно проверки, убедись что есть два профиля, и открой проверку заново."
            return
        }
        coordinator.start(
            first: firstProfile,
            second: secondProfile,
            runtime: runtime
        )
    }

    private func surfaceState(
        _ key: String,
        report: FingerprintAuditReport
    ) -> (title: String, icon: String, color: Color) {
        if report.unstableCriticalKeys.contains(key) {
            return ("Нестабильно", "exclamationmark.triangle.fill", .orange)
        }
        if report.changedCriticalKeys.contains(key) {
            return ("Отличается", "checkmark.circle.fill", .green)
        }
        if report.unavailableCriticalKeys.contains(key) {
            return ("Недоступно", "questionmark.circle.fill", .secondary)
        }
        return ("Одинаково", "equal.circle.fill", .secondary)
    }

    private func surfaceTitle(_ key: String) -> String {
        switch key {
        case "canvas": "Canvas"
        case "webgl_pixels": "WebGL"
        case "audio": "Audio"
        case "client_rects": "ClientRects"
        default: key
        }
    }

    private func verdictIcon(_ verdict: FingerprintAuditVerdict) -> String {
        switch verdict {
        case .verified: "checkmark.shield.fill"
        case .partial: "shield.lefthalf.filled"
        case .unchanged: "equal.circle.fill"
        case .unstable: "exclamationmark.triangle.fill"
        }
    }

    private func verdictColor(_ verdict: FingerprintAuditVerdict) -> Color {
        switch verdict {
        case .verified: .green
        case .partial: .orange
        case .unchanged: .red
        case .unstable: .orange
        }
    }
}
