import Foundation
import Testing
@testable import NeAntik

struct NeAntikErrorPresentationTests {
    @Test
    func emptyLaunchFailureExplainsSafeRecovery() {
        let message = NeAntikError.processLaunchFailed(" \n ")
            .localizedDescription

        #expect(message.contains("Диагностика среды"))
        #expect(message.contains("официального DMG"))
        #expect(message.contains("Данные профиля удалять не нужно"))
    }

    @Test
    func launchFailurePreservesAvailableSystemDetail() {
        let detail = "Operation not permitted"
        let message = NeAntikError.processLaunchFailed(detail)
            .localizedDescription

        #expect(message.contains(detail))
    }
}
