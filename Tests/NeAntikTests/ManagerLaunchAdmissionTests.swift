import Combine
import Foundation
import Testing
@testable import NeAntik

@MainActor
struct ManagerLaunchAdmissionTests {
    @Test func thermalAdmissionUsesOneSnapshotAndRejectsCriticalToSeriousTransition() throws {
        var reads = 0
        let admission = ManagerLaunchAdmission(observePressure: false, thermalState: {
            reads += 1
            return reads == 1 ? .critical : .serious
        })
        #expect(throws: ManagerLaunchAdmissionError.self) { try admission.begin(profileID: UUID()) }
        #expect(reads == 1)
        for state: ProcessInfo.ThermalState in [.nominal, .fair] {
            let safe = ManagerLaunchAdmission(observePressure: false, thermalState: { state })
            let token = try safe.begin(profileID: UUID())
            safe.finish(token: token)
        }
    }
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
    @Test func preparationChangesNotifyTheLaunchControls() throws {
        let admission = ManagerLaunchAdmission(observePressure: false, thermalState: { .nominal })
        let id = UUID()
        var notifications = 0
        let subscription = admission.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        let token = try admission.begin(profileID: id)
        #expect(admission.isPreparing)
        #expect(admission.preparingProfileID == id)
        #expect(notifications == 1)
        admission.finish(token: token)
        #expect(!admission.isPreparing)
        #expect(admission.preparingProfileID == nil)
        #expect(notifications == 2)
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
