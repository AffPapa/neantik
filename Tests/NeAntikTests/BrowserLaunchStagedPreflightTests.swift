import Foundation
import Testing

@testable import NeAntik

struct BrowserLaunchStagedPreflightTests {
    @Test
    func readyDirectAndProxyProfilesPassAllStages() throws {
        for profile in [
            BrowserProfile(name: "Direct"),
            BrowserProfile(
                name: "Proxy",
                proxy: ProxyConfiguration(
                    kind: .https,
                    host: "proxy.example",
                    port: 443,
                    username: ""
                )
            ),
        ] {
            try BrowserLaunchStagedPreflight.validate(
                input(profile: profile)
            )
        }
    }

    @Test
    func failuresAreOrderedAndNameOneActionableStage() {
        let profile = BrowserProfile(name: "Profile")
        let cases: [(BrowserLaunchPreflightInput, BrowserLaunchStage)] = [
            (
                input(
                    profile: profile,
                    runtime: BrowserRuntimePreflight(
                        errors: ["Повреждён"],
                        warnings: []
                    ),
                    storage: .unavailable,
                    processState: .recoveryRequired
                ),
                .runtime
            ),
            (input(profile: profile, storage: .readOnly), .storage),
            (
                input(
                    profile: BrowserProfile(
                        name: "Invalid proxy",
                        proxy: ProxyConfiguration(
                            kind: .https,
                            host: "",
                            port: 0,
                            username: ""
                        )
                    )
                ),
                .proxy
            ),
            (
                input(
                    profile: BrowserProfile(
                        name: "Archived",
                        isArchived: true
                    )
                ),
                .consistency
            ),
            (input(profile: profile, processState: .checking), .process),
        ]

        for (value, expectedStage) in cases {
            do {
                try BrowserLaunchStagedPreflight.validate(value)
                Issue.record("Expected \(expectedStage) to fail")
            } catch let failure as BrowserLaunchStagedFailure {
                #expect(failure.stage == expectedStage)
                #expect(failure.errorDescription?.contains(expectedStage.title) == true)
                #expect(!failure.recovery.isEmpty)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func lowDiskBlocksAtOneGiBBoundary() throws {
        let profile = BrowserProfile(name: "Disk")
        try BrowserLaunchStagedPreflight.validate(
            input(
                profile: profile,
                storage: .ready(
                    availableCapacity:
                        BrowserLaunchStagedPreflight.minimumAvailableCapacity
                )
            )
        )

        do {
            try BrowserLaunchStagedPreflight.validate(
                input(
                    profile: profile,
                    storage: .ready(
                        availableCapacity:
                            BrowserLaunchStagedPreflight.minimumAvailableCapacity - 1
                    )
                )
            )
            Issue.record("Expected low disk failure")
        } catch let failure as BrowserLaunchStagedFailure {
            #expect(failure.stage == .storage)
            #expect(!failure.errorDescription!.contains("/"))
        }
    }

    @Test
    func deepStorageFailureBlocksLaunchBeforeProxyAndProcessStages() {
        do {
            try BrowserLaunchStagedPreflight.validate(
                input(
                    profile: BrowserProfile(name: "Deep storage"),
                    storageIntegrity: .failed,
                    processState: .recoveryRequired
                )
            )
            Issue.record("Expected deep storage failure")
        } catch let failure as BrowserLaunchStagedFailure {
            #expect(failure.stage == .storage)
            #expect(failure.message.contains("временные данные"))
            #expect(!failure.errorDescription!.contains("/"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func input(
        profile: BrowserProfile,
        runtime: BrowserRuntimePreflight = BrowserRuntimePreflight(
            errors: [],
            warnings: []
        ),
        storage: WorkspaceStorageState = .ready(
            availableCapacity: 8 * 1_024 * 1_024 * 1_024
        ),
        storageIntegrity: WorkspaceStorageIntegrityState = .passed,
        processState: BrowserProfileProcessState = .stopped
    ) -> BrowserLaunchPreflightInput {
        BrowserLaunchPreflightInput(
            profile: profile,
            processState: processState,
            runtimePreflight: runtime,
            storage: storage,
            storageIntegrity: storageIntegrity
        )
    }
}
