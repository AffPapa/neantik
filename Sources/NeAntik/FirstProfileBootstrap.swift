import AppKit
import Foundation
import SwiftUI

enum FirstProfileBootstrap {
    static let defaultName = "Основной профиль"
    static let routeSummary = "Прямое подключение"

    static func makeProfile(
        existingProfiles: [BrowserProfile]
    ) -> BrowserProfile? {
        guard existingProfiles.isEmpty else { return nil }
        return BrowserProfile(name: defaultName)
    }
}

/// A bounded fast path for an existing workspace.
///
/// It deliberately creates only a permanent Direct profile. Proxy, note, tags
/// and appearance stay at safe defaults, while BrowserProfile issues a fresh
/// identifier and identity for every invocation. The workspace may still put
/// the result into the currently selected folder.
enum QuickProfileBootstrap {
    static let namePrefix = "Профиль"

    static func makeProfile(
        existingProfiles: [BrowserProfile]
    ) -> BrowserProfile {
        BrowserProfile(
            name: nextAvailableName(existingProfiles: existingProfiles)
        )
    }

    static func nextAvailableName(
        existingProfiles: [BrowserProfile]
    ) -> String {
        let existingNames = Set(existingProfiles.map {
            comparisonKey($0.name)
        })
        var number = max(2, existingProfiles.count + 1)
        while existingNames.contains(
            comparisonKey("\(namePrefix) \(number)")
        ) {
            number += 1
        }
        return "\(namePrefix) \(number)"
    }

    private static func comparisonKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "ru_RU")
        )
    }
}

enum FirstProfilePrimaryAction: Equatable, Sendable {
    case createAndOpen
    case retryRuntimeCheck
    case unavailable
}

struct FirstProfileOnboardingPresentation: Equatable, Sendable {
    let primaryAction: FirstProfilePrimaryAction
    let primaryTitle: String
    let primarySystemImage: String
    let primaryIsEnabled: Bool
    let primaryAccessibilityHint: String
    let statusMessage: String?
    let statusSystemImage: String?
    let terminalAccessibilityAnnouncement: String?

    static func resolve(
        runtimeAvailability: BrowserRuntimeAvailability,
        isCreatingProfile: Bool,
        resolutionIsDelayed: Bool = false
    ) -> Self {
        if isCreatingProfile {
            return Self(
                primaryAction: .unavailable,
                primaryTitle: "Создаём профиль…",
                primarySystemImage: "hourglass",
                primaryIsEnabled: false,
                primaryAccessibilityHint:
                    "Дождись создания постоянного профиля",
                statusMessage:
                    "Создаём постоянный локальный профиль.",
                statusSystemImage: "hourglass",
                terminalAccessibilityAnnouncement: nil
            )
        }

        switch runtimeAvailability {
        case .resolving:
            if resolutionIsDelayed {
                return Self(
                    primaryAction: .retryRuntimeCheck,
                    primaryTitle: "Повторить проверку",
                    primarySystemImage: "arrow.clockwise",
                    primaryIsEnabled: true,
                    primaryAccessibilityHint:
                        "Запускает новую проверку встроенного браузерного движка",
                    statusMessage:
                        "Проверка занимает больше обычного. Можно повторить её, не закрывая окно.",
                    statusSystemImage: "clock.badge.exclamationmark",
                    terminalAccessibilityAnnouncement:
                        "Проверка браузерного движка задержалась. Повторная проверка доступна."
                )
            }
            return Self(
                primaryAction: .unavailable,
                primaryTitle: "Проверяем браузер…",
                primarySystemImage: "hourglass",
                primaryIsEnabled: false,
                primaryAccessibilityHint:
                    "Кнопка станет доступна после проверки",
                statusMessage:
                    "Проверяем встроенный браузерный движок.",
                statusSystemImage: "hourglass",
                terminalAccessibilityAnnouncement: nil
            )

        case .ready:
            return Self(
                primaryAction: .createAndOpen,
                primaryTitle: "Создать и открыть",
                primarySystemImage: "play.fill",
                primaryIsEnabled: true,
                primaryAccessibilityHint:
                    "Создаёт постоянный профиль с прямым подключением " +
                    "и сразу запускает его",
                statusMessage: nil,
                statusSystemImage: nil,
                terminalAccessibilityAnnouncement:
                    "Браузерный движок готов. " +
                    "Можно создать и открыть профиль."
            )

        case .missing:
            return unavailableRuntime(
                message:
                    "Встроенный браузерный движок не найден. " +
                    "Переустанови NeAntik из официального DMG или ZIP, " +
                    "затем повтори проверку.",
                announcement:
                    "Браузерный движок не найден. " +
                    "Повторная проверка доступна."
            )

        case let .invalid(message):
            let detail = message.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let explanation = detail.isEmpty
                ? "Браузерный движок не готов. Повтори проверку."
                : "Браузерный движок не готов: \(detail)"
            return unavailableRuntime(
                message: explanation,
                announcement:
                    "Браузерный движок не готов. " +
                    "Повторная проверка доступна."
            )
        }
    }

    private static func unavailableRuntime(
        message: String,
        announcement: String
    ) -> Self {
        Self(
            primaryAction: .retryRuntimeCheck,
            primaryTitle: "Повторить проверку",
            primarySystemImage: "arrow.clockwise",
            primaryIsEnabled: true,
            primaryAccessibilityHint:
                "Повторно проверяет встроенный браузерный движок",
            statusMessage: message,
            statusSystemImage: "exclamationmark.triangle.fill",
            terminalAccessibilityAnnouncement: announcement
        )
    }
}

struct FirstProfileOnboardingView: View {
    @State private var runtimeResolutionIsDelayed = false

    let runtimeAvailability: BrowserRuntimeAvailability
    let isCreatingProfile: Bool
    let onCreateAndOpen: () -> Void
    let onRetryRuntimeCheck: () -> Void
    let onConfigure: () -> Void

    private var presentation: FirstProfileOnboardingPresentation {
        FirstProfileOnboardingPresentation.resolve(
            runtimeAvailability: runtimeAvailability,
            isCreatingProfile: isCreatingProfile,
            resolutionIsDelayed: runtimeResolutionIsDelayed
        )
    }

    var body: some View {
        ContentUnavailableView {
            Label(
                "Создай первый профиль",
                systemImage: "person.crop.rectangle.stack"
            )
        } description: {
            VStack(spacing: 6) {
                Text(
                    "NeAntik создаст постоянный локальный профиль браузера " +
                        "со стабильными настройками среды."
                )
                Label(
                    "Сеть: \(FirstProfileBootstrap.routeSummary)",
                    systemImage: "network"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let statusMessage = presentation.statusMessage,
                   let statusSystemImage = presentation.statusSystemImage
                {
                    UserNoticeLabel(
                        notice: UserNotice(
                            statusMessage,
                            level: runtimeAvailability == .resolving &&
                                !runtimeResolutionIsDelayed
                                ? .information
                                : .warning
                        )
                    )
                    .accessibilityHint(
                        statusSystemImage == "hourglass"
                            ? "Проверка выполняется"
                            : "Можно повторить проверку"
                    )
                }
            }
            .frame(maxWidth: 440)
        } actions: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    createAndOpenButton
                    configureButton
                }
                VStack(spacing: 8) {
                    createAndOpenButton
                    configureButton
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: runtimeAvailability) {
            runtimeResolutionIsDelayed = false
            guard runtimeAvailability == .resolving else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  runtimeAvailability == .resolving
            else { return }
            runtimeResolutionIsDelayed = true
            if let message = presentation.terminalAccessibilityAnnouncement {
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: message,
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue
                    ]
                )
            }
        }
        .onChange(of: runtimeAvailability) { previous, current in
            guard previous == .resolving,
                  let message = FirstProfileOnboardingPresentation.resolve(
                      runtimeAvailability: current,
                      isCreatingProfile: false
                  ).terminalAccessibilityAnnouncement
            else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority:
                        NSAccessibilityPriorityLevel.medium.rawValue
                ]
            )
        }
    }

    private var createAndOpenButton: some View {
        Button(action: performPrimaryAction) {
            Label(
                presentation.primaryTitle,
                systemImage: presentation.primarySystemImage
            )
            .frame(minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize(horizontal: true, vertical: false)
        .keyboardShortcut(.defaultAction)
        .disabled(!presentation.primaryIsEnabled)
        .accessibilityLabel(presentation.primaryTitle)
        .accessibilityHint(presentation.primaryAccessibilityHint)
    }

    private var configureButton: some View {
        Button("Настроить…", action: onConfigure)
            .frame(minHeight: 28)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isCreatingProfile)
            .accessibilityHint(
                "Открывает полную настройку профиля и прокси"
            )
    }

    private func performPrimaryAction() {
        switch presentation.primaryAction {
        case .createAndOpen:
            onCreateAndOpen()
        case .retryRuntimeCheck:
            onRetryRuntimeCheck()
        case .unavailable:
            break
        }
    }
}
