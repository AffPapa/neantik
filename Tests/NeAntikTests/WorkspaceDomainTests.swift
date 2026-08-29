import Foundation
import Testing
@testable import NeAntik

struct WorkspaceDomainTests {
    @Test
    func snapshotProjectsCanonicalOwnersIntoOneConsistentRevision() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let profile = BrowserProfile(
            name: "Workspace",
            tags: ["Работа"],
            note: "Локальная заметка",
            isPinned: true,
            proxy: ProxyConfiguration(
                kind: .https,
                host: "private-proxy.example",
                port: 443,
                username: "private-user"
            )
        )
        let folder = ProfileFolder(
            id: UUID(),
            name: "Клиенты",
            createdAt: now,
            updatedAt: now
        )
        let organization = ProfileOrganizationState(
            folders: [folder],
            assignmentsByProfileID: [profile.id: folder.id]
        )
        let health = ProxyHealthState(
            latestAttempt: ProxyHealthAttempt(
                checkedAt: now,
                outcome: .succeeded,
                responseTimeMilliseconds: 320
            ),
            lastSuccess: ProxyHealthSuccess(
                observedAt: now,
                responseTimeMilliseconds: 320,
                exitAddressWasObserved: true,
                city: "Berlin",
                countryName: "Germany",
                countryCode: "DE",
                timezoneIdentifier: "Europe/Berlin",
                localeIdentifier: "de-DE"
            )
        )

        let snapshot = WorkspaceDomain.snapshot(
            profiles: [profile],
            organization: organization,
            runningProfileIDs: [profile.id],
            proxyHealthStates: [profile.id: health],
            runtime: nil,
            now: now
        )

        #expect(snapshot.generatedAt == now)
        #expect(snapshot.folders.first?.profileCount == 1)
        #expect(snapshot.profiles.first?.folderID == folder.id)
        #expect(snapshot.profiles.first?.note == profile.note)
        #expect(snapshot.profiles.first?.isRunning == true)
        #expect(snapshot.profiles.first?.latestProxyOutcome == .succeeded)
        #expect(snapshot.environment(for: profile.id)?.generatedAt == now)
    }

    @Test
    func publicDTOHasNoCredentialEndpointOrFingerprintEvidenceFields() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let profile = BrowserProfile(
            name: "Workspace",
            note: "never-export-this-local-note",
            proxy: ProxyConfiguration(
                kind: .http,
                host: "secret-host.example",
                port: 8_080,
                username: "secret-user"
            ),
            identity: BrowserIdentity(seed: 987_654_321)
        )
        let snapshot = WorkspaceDomain.snapshot(
            profiles: [profile],
            organization: .empty,
            runningProfileIDs: [],
            proxyHealthStates: [:],
            runtime: nil,
            now: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot.publicDTO())
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(!text.contains("secret-host.example"))
        #expect(!text.contains("secret-user"))
        #expect(!text.contains("8080"))
        #expect(!text.contains("987654321"))
        #expect(!text.contains(profile.identity.displayCode))
        #expect(!text.contains("never-export-this-local-note"))
        #expect(!text.contains("\"note\""))
        #expect(!text.localizedCaseInsensitiveContains("password"))
        #expect(!text.localizedCaseInsensitiveContains("browserData"))
        #expect(!text.localizedCaseInsensitiveContains("webrtc"))
    }

    @Test
    func canonicalSnapshotUsesOnlyTypedFingerprintObservation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let profile = BrowserProfile(name: "Observed")
        let runtime = BrowserRuntime(
            name: "NeAntik Browser",
            executableURL: URL(fileURLWithPath: "/tmp/NeAntik Browser"),
            source: "Test",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(
                version: "151",
                architectures: ["arm64"],
                codeSignatureValid: true
            )
        )
        let rawObservation = ValidatedProfileFingerprintObservation(
            profileID: profile.id,
            observedAt: now,
            route: .direct,
            verdict: .verified,
            webRTCLoopback: .passed
        )
        let observation = try #require(
            rawObservation.bound(to: profile, runtime: runtime)
        )

        let snapshot = WorkspaceDomain.snapshot(
            profiles: [profile],
            organization: .empty,
            runningProfileIDs: [],
            proxyHealthStates: [:],
            runtime: runtime,
            fingerprintObservations: [profile.id: observation],
            now: now
        )
        let environment = try #require(snapshot.environment(for: profile.id))
        let fields = environment.sections.flatMap(\.fields)

        #expect(
            fields.first { $0.id == "fingerprint.observation" }?.state ==
                .observed
        )
        #expect(
            fields.first { $0.id == "webrtc.loopback" }?.state == .observed
        )
    }
}
