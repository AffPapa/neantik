import AppKit
import SwiftUI

struct ApplicationUpdateSheet: View {
    static let latestReleaseURL = URL(string: "https://github.com/AffPapa/neantik/releases/latest")!
    @ObservedObject var controller: ApplicationUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("page.314", tableName: "Pages", bundle: .main, value: "Обновление NeAntik", comment: "")).font(.title2.bold())
            if controller.channelEnabled {
                Text(NSLocalizedString("page.315", tableName: "Pages", bundle: .main, value: "Проверка подписи, версии движка и целостности проходит до установки. После подтверждения NeAntik закроется и откроет новую версию.", comment: ""))
                    .fixedSize(horizontal: false, vertical: true)
                if let version = controller.offeredVersion {
                    LabeledContent(NSLocalizedString("page.316", tableName: "Pages", bundle: .main, value: "Проверенный кандидат", comment: ""), value: version).font(.headline)
                    Text(NSLocalizedString("page.317", tableName: "Pages", bundle: .main, value: "Нажатие кнопки ниже разрешает установку и перезапуск.", comment: "")).foregroundStyle(.secondary)
                }
                if let version = controller.manifestVersion, controller.offeredVersion == nil {
                    LabeledContent(NSLocalizedString("page.318", tableName: "Pages", bundle: .main, value: "Версия в подписанном канале", comment: ""), value: version)
                    Text(NSLocalizedString("page.319", tableName: "Pages", bundle: .main, value: "Архив ещё не проверен и установка не началась.", comment: "")).foregroundStyle(.secondary)
                }
                if controller.phase == .discovering || controller.phase == .downloading || controller.phase == .checking || controller.phase == .cancelling || controller.phase == .committing {
                    ProgressView(controller.phase == .discovering ? NSLocalizedString("page.320", tableName: "Pages", bundle: .main, value: "Проверка подписанного канала…", comment: "") : controller.phase == .downloading ? NSLocalizedString("page.321", tableName: "Pages", bundle: .main, value: "Загрузка ZIP…", comment: "") : controller.phase == .checking ? NSLocalizedString("page.322", tableName: "Pages", bundle: .main, value: "Проверка файлов…", comment: "") : NSLocalizedString("page.236", tableName: "Pages", bundle: .main, value: "Завершение операции…", comment: ""))
                }
            } else {
                Text(NSLocalizedString("page.323", tableName: "Pages", bundle: .main, value: "В этой версии обновление выполняется вручную.", comment: "")).font(.headline)
                Text(NSLocalizedString("page.324", tableName: "Pages", bundle: .main, value: "Скачай последний DMG или ZIP со страницы релизов NeAntik на GitHub. Закрой браузерные окна и NeAntik, затем перенеси новое приложение в «Программы». Не удаляй данные профилей.", comment: ""))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = controller.message {
                Label(message, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Link(NSLocalizedString("page.325", tableName: "Pages", bundle: .main, value: "Открыть последние релизы GitHub", comment: ""), destination: Self.latestReleaseURL)
                Spacer()
                if controller.canCancel {
                    Button(NSLocalizedString("page.252", tableName: "Pages", bundle: .main, value: "Отменить проверку", comment: ""), action: controller.cancel).keyboardShortcut(.cancelAction)
                } else if controller.canClose {
                    Button(NSLocalizedString("page.218", tableName: "Pages", bundle: .main, value: "Закрыть", comment: ""), action: controller.close).keyboardShortcut(.cancelAction)
                }
                if controller.phase == .idle, controller.holdsFence {
                    Button(NSLocalizedString("page.326", tableName: "Pages", bundle: .main, value: "Проверить обновления", comment: ""), action: controller.checkForUpdates)
                    if controller.hasRetrievedManifest { Button(NSLocalizedString("page.327", tableName: "Pages", bundle: .main, value: "Скачать и проверить ZIP", comment: ""), action: controller.downloadAndInspect) }
                    Button(controller.hasRetrievedManifest ? NSLocalizedString("page.328", tableName: "Pages", bundle: .main, value: "Выбрать ZIP…", comment: "") : NSLocalizedString("page.329", tableName: "Pages", bundle: .main, value: "Выбрать файлы…", comment: ""), action: controller.chooseFiles).keyboardShortcut(.defaultAction)
                }
                if controller.phase == .offered {
                    Button(NSLocalizedString("page.330", tableName: "Pages", bundle: .main, value: "Установить и перезапустить", comment: ""), action: controller.installAndRestart).keyboardShortcut(.defaultAction)
                }
                if controller.phase == .restartRequired {
                    Button(NSLocalizedString("page.331", tableName: "Pages", bundle: .main, value: "Закрыть NeAntik", comment: ""), action: controller.dismissForTermination)
                }
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 600, maxWidth: 680)
        .interactiveDismissDisabled(true)
        .onDisappear { controller.sheetDidDisappear() }
    }
}
