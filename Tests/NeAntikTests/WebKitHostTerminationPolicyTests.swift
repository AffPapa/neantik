import Foundation
import Testing
@testable import NeAntik

@Suite struct WebKitHostTerminationPolicyTests {
    @Test func staleGenerationCannotCleanUpReplacementSession() {
        #expect(WebKitHostTerminationPolicy.action(
            exitedGeneration: UUID(uuidString: "4c73ef23-21cb-47c9-a756-23b9718b7751")!,
            currentGeneration: UUID(uuidString: "ec25f7f5-9aa4-4ab7-94d0-06c514bcb03b")!,
            launchInProgress: false, closeInProgress: false) == .ignore)
    }

    @Test func intentionalCloseUsesSaveHandshakeInsteadOfCrashCleanup() {
        let generation = UUID(uuidString: "d28e414e-3892-4bd2-b353-54ae81da2dc5")!
        #expect(WebKitHostTerminationPolicy.action(
            exitedGeneration: generation, currentGeneration: generation,
            launchInProgress: false, closeInProgress: true) == .ignore)
    }

    @Test func exitDuringStartupIsDeferredToLaunchFailureCleanup() {
        let generation = UUID(uuidString: "6e69d15b-465a-4c0e-955b-675c42e36d21")!
        #expect(WebKitHostTerminationPolicy.action(
            exitedGeneration: generation, currentGeneration: generation,
            launchInProgress: true, closeInProgress: false) == .deferUntilLaunchSettles)
    }

    @Test func activeUnexpectedExitRequestsGenerationScopedCleanup() {
        let generation = UUID(uuidString: "b89a09c7-cf2f-4f64-ae49-33111f96828d")!
        #expect(WebKitHostTerminationPolicy.action(
            exitedGeneration: generation, currentGeneration: generation,
            launchInProgress: false, closeInProgress: false) == .reconcileUnexpectedExit)
    }
}
