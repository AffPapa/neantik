import Foundation
import Testing
@testable import NeAntik

@MainActor
@Suite(.serialized)
struct BrowserFontPolicyTests {
    private func encoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }

    private func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    private func fixture(policy: BrowserFontPolicy = .native) -> BrowserProfile {
        BrowserProfile(name: "Own font policy fixture", fontPolicy: policy,
            identity: BrowserIdentity(seed: 33),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func missingPolicyPreservesLegacyIdentityAndRevision() throws {
        var original = fixture()
        original.revision = 19
        var record = try #require(JSONSerialization.jsonObject(
            with: encoder().encode(original)) as? [String: Any])
        record.removeValue(forKey: "fontPolicy")
        let loaded = try decoder().decode(BrowserProfile.self,
            from: JSONSerialization.data(withJSONObject: record))
        #expect(loaded.fontPolicy == .native)
        #expect(loaded.id == original.id && loaded.identity == original.identity)
        #expect(loaded.revision == 19)
    }

    @Test(arguments: ["null", "unknown", "numeric"])
    func unsupportedPolicyCannotTriggerOlderSnapshotRecovery(change: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-font-metadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let original = fixture()
        var record = try #require(JSONSerialization.jsonObject(
            with: encoder().encode(original)) as? [String: Any])
        switch change {
        case "null": record["fontPolicy"] = NSNull()
        case "unknown": record["fontPolicy"] = "future-system-v2"
        default: record["fontPolicy"] = 1
        }
        let primary = try JSONSerialization.data(withJSONObject:
            ["schemaVersion": 4, "profiles": [record]])
        let backup = try ProfileStore.encodeProfiles([original], encoder: encoder())
        try paths.writePrivateFile(primary, to: paths.profilesFile)
        try paths.writePrivateFile(backup, to: paths.profilesBackupFile)

        #expect(throws: UnsupportedBrowserFontPolicyError.self) {
            try decoder().decode(BrowserProfile.self,
                from: JSONSerialization.data(withJSONObject: record))
        }
        let store = ProfileStore(paths: paths)
        #expect(!store.hasTrustedMetadata)
        #expect(store.lastError?.contains("политику шрифтов") == true)
        #expect(throws: (any Error).self) { try store.upsert(fixture()) }
        #expect(try Data(contentsOf: paths.profilesFile) == primary)
        #expect(try Data(contentsOf: paths.profilesBackupFile) == backup)
    }

    @Test(arguments: [BrowserFontPolicy.native, .systemV1])
    func explicitPolicyRoundTripsWithoutChangingIdentity(policy: BrowserFontPolicy) throws {
        let original = fixture(policy: policy)
        let encoded = try ProfileStore.encodeProfiles([original], encoder: encoder())
        let loaded = try #require(ProfileStore.decodeProfiles(encoded).first)
        #expect(loaded == original)
        if policy == .native {
            #expect(encoded.first == 91) // Existing Chromium array contract.
        } else {
            let envelope = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(envelope["schemaVersion"] as? Int == 4)
        }
    }

    @Test func fontEnvelopeTakesPrecedenceOverWebKitMediaVersion() throws {
        let webkit = BrowserProfile(name: "Own WebKit metadata", startURL: "about:blank",
            engine: .webkit, webKitMediaPolicy: .deny)
        let data = try ProfileStore.encodeProfiles([webkit, fixture(policy: .systemV1)], encoder: encoder())
        let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(envelope["schemaVersion"] as? Int == 4)
        let loaded = try ProfileStore.decodeProfiles(data)
        #expect(loaded[0].engine == .webkit && loaded[0].webKitMediaPolicy == .deny)
        #expect(loaded[1].fontPolicy == .systemV1)
    }

    @Test(arguments: [1, 2, 3])
    func policyCannotBeDisguisedAsOlderEnvelope(version: Int) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-font-schema-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let entries = try JSONSerialization.jsonObject(with: encoder().encode([fixture(policy: .systemV1)]))
        let primary = try JSONSerialization.data(withJSONObject:
            ["schemaVersion": version, "profiles": entries])
        let backup = try ProfileStore.encodeProfiles([fixture()], encoder: encoder())
        try paths.writePrivateFile(primary, to: paths.profilesFile)
        try paths.writePrivateFile(backup, to: paths.profilesBackupFile)
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(primary) }
        let store = ProfileStore(paths: paths)
        #expect(!store.hasTrustedMetadata)
        #expect(try Data(contentsOf: paths.profilesFile) == primary)
        #expect(try Data(contentsOf: paths.profilesBackupFile) == backup)
    }

    @Test func policyCannotBeDisguisedAsLegacyArray() throws {
        let data = try encoder().encode([fixture(policy: .systemV1)])
        #expect(throws: (any Error).self) { try ProfileStore.decodeProfiles(data) }
    }

    @Test func copiesRetainFontPolicyWhilePortableConfigurationsSnapshotsAndTemplatesStayNative() throws {
        let original = fixture(policy: .systemV1)
        let copy = original.duplicated()
        let configuration = try ProfileConfigurationTransferDocument(profiles: [original])
        let imported = try #require(configuration.makeProfiles().first)
        let snapshot = try ProfileSnapshotDocument(profiles: [original], folderNameByProfileID: [:])
        let restoredMetadata = try #require(snapshot.makeProfiles().first)
        let template = try UserProfileTemplate(name: "Own template", profile: original, folderID: nil)
        let fromTemplate = template.makeProfile()
        #expect(copy.fontPolicy == .systemV1 && copy.id != original.id)
        for profile in [imported, restoredMetadata, fromTemplate] {
            #expect(profile.fontPolicy == .native)
            #expect(profile.id != original.id)
        }
        #expect(configuration.schemaVersion == 1)
        #expect(original.fontPolicy == .systemV1 && original.identity.seed == 33)
    }

    @Test func directImportRejectsPolicyBeforeCreatingRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-font-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        #expect(throws: (any Error).self) {
            try ProfileMetadataImportTransaction.run(paths: paths,
                requestedProfiles: [fixture(policy: .systemV1)], folderNames: [nil])
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func portableAndSnapshotImportsAcceptDerivedFontPolicyWithoutCopyingIdentity() throws {
        for mode in ["balanced", "strict", "custom"] {
            var policy = mode == "strict" ? BrowserPrivacyPolicy.strict : .balanced
            if mode == "custom" { policy.trackingParameterCleanup = false }
            let original = BrowserProfile(name: "Synthetic \(mode)", fontPolicy: .systemV1,
                                          privacyPolicy: policy, identity: BrowserIdentity(seed: 33))
            let portable = try ProfileConfigurationTransferDocument(profiles: [original])
            let snapshot = try ProfileSnapshotDocument(profiles: [original], folderNameByProfileID: [:])
            for imported in [try portable.makeProfiles(), try snapshot.makeProfiles()] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-font-portable-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let paths = AppPaths(rootDirectory: root)
                try paths.prepareBaseDirectories()
                let fresh = try #require(imported.first)
                #expect(fresh.fontPolicy == .systemV1 && fresh.privacyPolicy == policy)
                #expect(fresh.id != original.id && fresh.identity != original.identity)
                let result = try ProfileMetadataImportTransaction.run(paths: paths, requestedProfiles: imported, folderNames: [nil])
                let saved = try #require(result.insertedProfiles.first)
                #expect(saved.fontPolicy == .systemV1 && saved.privacyPolicy == policy)
                #expect(try #require(ProfileStore(paths: paths).profile(withID: saved.id)).privacyPolicy == policy)
            }
        }
    }

    @Test func importedSystemFontPolicyStillRejectsIncompatibleEnginesAndLegacy() throws {
        for engine in [BrowserEngine.chromium, .webkit] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-font-import-denied-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let privacy: BrowserPrivacyPolicy = engine == .chromium ? .legacy : .balanced
            let profile = BrowserProfile(name: "Denied", engine: engine, fontPolicy: .systemV1, privacyPolicy: privacy)
            #expect(throws: (any Error).self) {
                try ProfileMetadataImportTransaction.run(paths: AppPaths(rootDirectory: root), requestedProfiles: [profile], folderNames: [nil])
            }
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test func ordinaryMetadataEditPreservesExplicitPolicyAndIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-font-edit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let original = try store.upsert(fixture(policy: .systemV1))
        var renamed = original
        renamed.name = "Renamed own fixture"
        let saved = try store.upsert(renamed)
        let reloaded = try #require(ProfileStore(paths: paths).profile(withID: original.id))
        #expect(reloaded.fontPolicy == .systemV1)
        #expect(reloaded.identity == original.identity)
        #expect(reloaded.revision == saved.revision && saved.revision > original.revision)
    }

    @Test(arguments: [false, true])
    func launchSnapshotIncludesPolicyEvenWhenRevisionMatches(changeDisk: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-font-snapshot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), store = ProfileStore(paths: paths)
        let original = try store.upsert(fixture())
        var changed = original
        changed.fontPolicy = .systemV1
        if changeDisk {
            try paths.writePrivateFile(ProfileStore.encodeProfiles([changed], encoder: encoder()),
                to: paths.profilesFile)
        }
        let expected = changeDisk ? original : changed
        #expect(throws: BrowserProfileRevisionConflictError.self) {
            try ProfileStore.withPersistedLaunchSnapshot(expected, paths: paths) { true }
        }
    }

    @Test func webKitCannotUseChromiumFontPolicy() throws {
        let profile = BrowserProfile(name: "Own invalid WebKit fixture", startURL: "about:blank",
            engine: .webkit, fontPolicy: .systemV1)
        #expect(profile.normalizedForPersistence() == nil)
        #expect(throws: UnsupportedBrowserFontPolicyError.self) {
            try WebKitProfilePolicy.validateConfiguration(profile)
        }
        #expect(throws: UnsupportedBrowserFontPolicyError.self) {
            try decoder().decode(BrowserProfile.self, from: encoder().encode(profile))
        }
    }

    @Test func unqualifiedRuntimeCannotSilentlyIgnorePolicy() throws {
        try BrowserLaunchPolicy.validateFontPolicy(fixture())
        #expect(throws: UnsupportedBrowserFontPolicyError.self) {
            try BrowserLaunchPolicy.validateFontPolicy(fixture(policy: .systemV1))
        }
        // Existing flavor/seed capabilities are not font qualification.
        for flavor in BrowserRuntimeFlavor.allCases {
            let environment = BrowserLaunchBuilder.environment(profile: fixture(policy: .systemV1),
                runtimeCapabilities: flavor.capabilities, inherited:
                    ["NEANTIK_FONT_POLICY": "system-v1", "NEANTIK_FONT_POLICY_QA": "renderer-witness-v1"])
            #expect(environment["NEANTIK_FONT_POLICY"] == nil)
            #expect(environment["NEANTIK_FONT_POLICY_QA"] == nil)
        }
    }

    @Test func processBoundaryRefusesPolicyBeforeAdmissionOrFilesystemWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-font-launch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        var admissionReads = 0
        let admission = ManagerLaunchAdmission(observePressure: false, thermalState: {
            admissionReads += 1
            return .critical
        })
        let manager = BrowserProcessManager(launchAdmission: admission, paths: paths,
            processIdentityValidator: { _ in false })
        // No real runtime is inspected or executed. If the font gate is removed,
        // critical admission produces the wrong error and this control fails.
        let runtime = BrowserRuntime(name: "Unexecuted fixture",
            executableURL: root.appendingPathComponent("must-not-execute"), source: "test",
            flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(version: nil, architectures: [], codeSignatureValid: nil))
        #expect(throws: UnsupportedBrowserFontPolicyError.self) {
            try manager.launch(profile: fixture(policy: .systemV1), runtime: runtime)
        }
        #expect(admissionReads == 0)
        #expect(manager.runningProfileIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test(arguments: [ProxyKind.http, .https, .socks5])
    func authenticatedRelayRefusesPolicyBeforeAdmissionOrFilesystemWork(kind: ProxyKind) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neantik-font-relay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var admissionReads = 0
        let manager = BrowserProcessManager(launchAdmission: ManagerLaunchAdmission(
            observePressure: false, thermalState: { admissionReads += 1; return .critical }),
            paths: AppPaths(rootDirectory: root), processIdentityValidator: { _ in false })
        defer { manager.suspendPassiveObservations() }
        let now = Date()
        var profile = fixture(policy: .systemV1)
        profile.proxy = ProxyConfiguration(kind: kind, host: "owned.example.test", port: 8000,
            username: "fixture-user")
        profile.identity = BrowserIdentity(seed: 33, timezoneIdentifier: "Europe/Berlin",
            localeIdentifier: "de-DE", proxyContextEvidence: .ipAPI(observedAt: now))
        let health = ProxyHealthUpdatePolicy.success(ProxyTestObservation(observedAt: now,
            responseTimeMilliseconds: 1, result: ProxyTestResult(ipAddress: "203.0.113.7",
                city: "Berlin", countryName: "Germany", countryCode: "DE",
                timezoneIdentifier: "Europe/Berlin", localeIdentifier: "de-DE"), source: .ipAPI))
        let receipt = try #require(BrowserLaunchPreparationPolicy.receipt(profile: profile,
            proxyHealth: health, now: now))
        let runtime = BrowserRuntime(name: "Never executed", executableURL: root.appendingPathComponent("missing"),
            source: "Synthetic", flavor: .fingerprintChromium,
            inspection: BrowserRuntimeInspection(version: nil, architectures: [], codeSignatureValid: nil))
        let keychain = KeychainStore(backend: DevelopmentFixtureKeychain(), service: "owned-font-relay", legacyService: nil)
        do {
            try await manager.launchWithAuthenticatedRelay(profile: profile, runtime: runtime,
                preparationReceipt: receipt, keychain: keychain)
            Issue.record("Unsupported font policy reached authenticated relay")
        } catch {
            #expect(error is UnsupportedBrowserFontPolicyError)
        }
        #expect(admissionReads == 0)
        #expect(manager.runningProfileIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

}
