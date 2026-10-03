import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ManagerLaunchAdmissionTests {
    @Test func oneSlotCancellationAndStaleCompletion() throws {
        let admission = ManagerLaunchAdmission(observePressure: false, thermalState: { .nominal })
        let id = UUID(), now = Date()
        let token = try admission.begin(profileID: id, now: now)
        #expect(throws: ManagerLaunchAdmissionError.self) { try admission.begin(profileID: id, now: now) }
        #expect(throws: ManagerLaunchAdmissionError.self) { try admission.begin(profileID: UUID(), now: now) }
        admission.finish(token: token, now: now)
        let next = try admission.begin(profileID: UUID(), now: now)
        admission.finish(token: token, now: now)
        #expect(throws: ManagerLaunchAdmissionError.self) { try admission.begin(profileID: UUID(), now: now) }
        admission.finish(token: next, launched: true, now: now)
        #expect(throws: ManagerLaunchAdmissionError.self) { try admission.begin(profileID: UUID(), now: now) }
        _ = try admission.begin(profileID: UUID(), now: now.addingTimeInterval(2))
    }
    @Test func pressureAndThermalOnlyBlockNewStarts() throws {
        let admission = ManagerLaunchAdmission(observePressure: false, thermalState: { .nominal })
        let token = try admission.begin(profileID: UUID())
        admission.setPressureForTesting(true)
        admission.finish(token: token)
        #expect(throws: ManagerLaunchAdmissionError.self) { try admission.begin(profileID: UUID()) }
        admission.setPressureForTesting(false)
        _ = try admission.begin(profileID: UUID())
        let hot = ManagerLaunchAdmission(observePressure: false, thermalState: { .serious })
        #expect(throws: ManagerLaunchAdmissionError.self) { try hot.begin(profileID: UUID()) }
    }
}
