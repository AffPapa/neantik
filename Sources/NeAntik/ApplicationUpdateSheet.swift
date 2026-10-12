import AppKit
import SwiftUI

struct ApplicationUpdateSheet: View {
    @ObservedObject var controller: ApplicationUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Обновление NeAntik").font(.title2.bold())
            if controller.channelEnabled {
                Text("Проверка подписи, версии движка и целостности проходит до установки. После подтверждения NeAntik закроется и откроет новую версию.")
                    .fixedSize(horizontal: false, vertical: true)
                if let version = controller.offeredVersion {
                    LabeledContent("Проверенный кандидат", value: version).font(.headline)
                    Text("Нажатие кнопки ниже разрешает установку и перезапуск.").foregroundStyle(.secondary)
                }
                if let version = controller.manifestVersion, controller.offeredVersion == nil {
                    LabeledContent("Версия в подписанном канале", value: version)
                    Text("Архив ещё не проверен и установка не началась.").foregroundStyle(.secondary)
                }
                if controller.phase == .discovering || controller.phase == .checking || controller.phase == .cancelling || controller.phase == .committing {
                    ProgressView(controller.phase == .discovering ? "Проверка подписанного канала…" : controller.phase == .checking ? "Проверка файлов…" : "Завершение операции…")
                }
            } else {
                Text("В этой версии обновление выполняется вручную.").font(.headline)
                Text("Скачай DMG или ZIP с сайта NeAntik. Закрой браузерные окна и NeAntik, затем перенеси новое приложение в «Программы». Не удаляй данные профилей.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = controller.message {
                Label(message, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Link("Скачать с сайта", destination: URL(string: "https://browser.free/#install")!)
                Spacer()
                if controller.canCancel {
                    Button("Отменить проверку", action: controller.cancel).keyboardShortcut(.cancelAction)
                } else if controller.canClose {
                    Button("Закрыть", action: controller.close).keyboardShortcut(.cancelAction)
                }
                if controller.phase == .idle, controller.holdsFence {
                    Button("Проверить обновления", action: controller.checkForUpdates)
                    Button(controller.hasRetrievedManifest ? "Выбрать ZIP…" : "Выбрать файлы…", action: controller.chooseFiles).keyboardShortcut(.defaultAction)
                }
                if controller.phase == .offered {
                    Button("Установить и перезапустить", action: controller.installAndRestart).keyboardShortcut(.defaultAction)
                }
                if controller.phase == .restartRequired {
                    Button("Закрыть NeAntik", action: controller.dismissForTermination)
                }
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 600, maxWidth: 680)
        .interactiveDismissDisabled(true)
        .onDisappear { controller.sheetDidDisappear() }
    }
}
