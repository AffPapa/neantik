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
        isCreatingProfile: Bool
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
    let runtimeAvailability: BrowserRuntimeAvailability
    let isCreatingProfile: Bool
    let onCreateAndOpen: () -> Void
    let onRetryRuntimeCheck: () -> Void
    let onConfigure: () -> Void

    private var presentation: FirstProfileOnboardingPresentation {
        FirstProfileOnboardingPresentation.resolve(
            runtimeAvailability: runtimeAvailability,
            isCreatingProfile: isCreatingProfile
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
                    Label(statusMessage, systemImage: statusSystemImage)
                        .font(.caption)
                        .foregroundStyle(
                            runtimeAvailability == .missing
                                ? Color.red
                                : Color.secondary
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(statusMessage)
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
