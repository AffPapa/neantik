import Foundation
import Testing
@testable import NeAntik

@Suite(.serialized) @MainActor
struct MCPProfileManagementTests {
    @Test func readOnlyStatusRejectsRevisionChangedDuringInventory() async throws {
        let (root, writer, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try writer.store.upsert(BrowserProfile(name: "Synthetic revision race"))
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let reader = MCPProfileManagement(root: root, allowsManagement: false,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil), readOnlyInventory: {
                entered.signal()
                _ = resume.wait(timeout: .now() + 3)
                return .unavailable
            })
        let request = Task { try await reader.call("profile_status", ["profileID": profile.id.uuidString,
            "includeObservation": true, "expectedRevision": String(profile.revision)]) }
        defer { request.cancel(); resume.signal() }
        #expect(await Task.detached { entered.wait(timeout: .now() + 3) }.value == .success)
        var changed = profile
        changed.name = "Synthetic changed revision"
        let updated = try writer.store.upsert(changed)
        #expect(updated.revision != profile.revision)
        resume.signal()
        await #expect(throws: MCPProfileManagement.Failure.self) { try await request.value }
    }

    @Test func readOnlyStatusCancelsInventoryWorker() async throws {
        let (root, writer, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try writer.store.upsert(BrowserProfile(name: "Synthetic cancellation"))
        let entered = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
        let reader = MCPProfileManagement(root: root, allowsManagement: false,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil), readOnlyInventory: {
                entered.signal()
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                cancelled.signal()
                return .unavailable
            })
        let request = Task { try await reader.call("profile_status", ["profileID": profile.id.uuidString]) }
        defer { request.cancel() }
        #expect(await Task.detached { entered.wait(timeout: .now() + 3) }.value == .success)
        request.cancel()
        #expect(await Task.detached { cancelled.wait(timeout: .now() + 3) }.value == .success)
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    @Test func readOnlyGuardRefusesSymlinkParentAndOpenPermissions() async throws {
        let (root, writer, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writer.store.upsert(BrowserProfile(name: "Synthetic guard safety"))
        let paths = AppPaths(rootDirectory: root)
        let original = paths.processLocksDirectory
        let moved = root.appendingPathComponent("SyntheticLocks")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        let keychain = KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil)
        let symlinkReader = MCPProfileManagement(root: root, allowsManagement: false, keychain: keychain)
        #expect(!symlinkReader.store.hasTrustedMetadata)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: moved, to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: paths.profilesMetadataGuardFile.path)
        let openReader = MCPProfileManagement(root: root, allowsManagement: false, keychain: keychain)
        #expect(!openReader.store.hasTrustedMetadata)
        let attrs = try FileManager.default.attributesOfItem(atPath: paths.profilesMetadataGuardFile.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o666)
    }

    @Test func readOnlyMetadataDoesNotCreateOrRepairMissingGuard() async throws {
        let (root, writer, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writer.store.upsert(BrowserProfile(name: "Synthetic guarded profile"))
        let paths = AppPaths(rootDirectory: root)
        let metadata = try Data(contentsOf: paths.profilesFile)
        try FileManager.default.removeItem(at: paths.profilesMetadataGuardFile)
        let reader = MCPProfileManagement(root: root, allowsManagement: false,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil))
        #expect(!reader.store.hasTrustedMetadata)
        await #expect(throws: (any Error).self) { try await reader.call("profile_get", ["profileID": UUID().uuidString]) }
        #expect(!FileManager.default.fileExists(atPath: paths.profilesMetadataGuardFile.path))
        #expect(try Data(contentsOf: paths.profilesFile) == metadata)
    }

    @Test func readOnlyRefreshRefusesRemovedGuardWithoutRecreatingIt() async throws {
        let (root, writer, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try writer.store.upsert(BrowserProfile(name: "Synthetic guard removal"))
        let paths = AppPaths(rootDirectory: root)
        let reader = MCPProfileManagement(root: root, allowsManagement: false,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil))
        _ = try await reader.call("profile_get", ["profileID": profile.id.uuidString])
        try FileManager.default.removeItem(at: paths.profilesMetadataGuardFile)
        await #expect(throws: (any Error).self) { try await reader.call("profile_get", ["profileID": profile.id.uuidString]) }
        #expect(!reader.store.hasTrustedMetadata)
        #expect(!FileManager.default.fileExists(atPath: paths.profilesMetadataGuardFile.path))
    }

    @Test func readOnlyStatusDoesNotReconcileOrClearOtherProfiles() async throws {
        let (root, writer, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = try writer.store.upsert(BrowserProfile(name: "Requested synthetic profile"))
        var policy = BrowserPrivacyPolicy.strict; policy.retention = .ephemeral
        let other = try writer.store.upsert(BrowserProfile(name: "Other synthetic profile", privacyPolicy: policy))
        let paths = AppPaths(rootDirectory: root)
        try EphemeralProfileStorage.prepareLaunch(paths: paths, profile: other)
        let state = paths.browserDataDirectory(for: other.id).appendingPathComponent("synthetic-state")
        let original = Data("retain this synthetic data".utf8)
        try original.write(to: state)
        let lease = paths.lockFile(for: requested.id)
        let leaseBytes = Data("synthetic stale lease".utf8)
        try leaseBytes.write(to: lease)
        let reader = MCPProfileManagement(root: root, allowsManagement: false,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil),
            readOnlyInventory: { .unavailable })
        let result = try await reader.call("profile_status", ["profileID": requested.id.uuidString])
        #expect(result["processState"] as? String == "unverified")
        let observed = try await reader.call("profile_status", ["profileID": requested.id.uuidString,
            "includeObservation": true, "expectedRevision": String(requested.revision)])
        #expect(observed["processState"] as? String == "unverified")
        let dataPath = paths.browserDataDirectory(for: requested.id).path
        let inventory = BrowserProcessInventory(processes: [123: BrowserProcessArguments(executablePath: "/synthetic/browser", arguments: ["--user-data-dir=\(dataPath)"])])
        let foundReader = MCPProfileManagement(root: root, allowsManagement: false,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil), readOnlyInventory: { inventory })
        let found = try await foundReader.call("profile_status", ["profileID": requested.id.uuidString])
        #expect(found["processState"] as? String == "externalUnverified")
        #expect(try EphemeralProfileStorage.pending(paths: paths, profile: other))
        #expect(try Data(contentsOf: state) == original)
        #expect(try Data(contentsOf: lease) == leaseBytes)
    }

    @Test func presetUpdateDisclosesAndPreservesOmittedFontPolicy() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try engine.store.upsert(BrowserProfile(name: "Synthetic native fonts", fontPolicy: .native, privacyPolicy: .legacy))
        let updated = try await engine.call("profile_update", ["profileID": original.id.uuidString,
            "expectedRevision": String(original.revision), "changes": ["privacyPreset": "strict"]])
        #expect(updated["fontPolicy"] as? String == "native")
        #expect(engine.store.profile(withID: original.id)?.fontPolicy == .native)
        let definition = try #require(MCPProfileManagement.definitions(allowsManagement: true).first { $0["name"] as? String == "profile_update" })
        let input = try #require(definition["inputSchema"] as? [String: Any])
        let properties = try #require(input["properties"] as? [String: Any])
        let changes = try #require(properties["changes"] as? [String: Any])
        let changeProperties = try #require(changes["properties"] as? [String: Any])
        let preset = try #require(changeProperties["privacyPreset"] as? [String: Any])
        #expect((preset["description"] as? String)?.contains("Omitted fontPolicy is preserved") == true)
    }

    @Test func protectedDefaultsAndPresetChangesPreserveDisposableRetention() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fresh = try await engine.call("profile_create", ["name": "Own safe default"])
        #expect(fresh["fontPolicy"] as? String == "system-v1")
        #expect((fresh["privacyPolicyIntent"] as? [String: Any])?["preset"] as? String == "balanced")
        var policy = BrowserPrivacyPolicy.strict; policy.retention = .ephemeral
        let own = try engine.store.upsert(BrowserProfile(name: "Own disposable policy", fontPolicy: .systemV1, privacyPolicy: policy))
        _ = try await engine.call("profile_update", ["profileID": own.id.uuidString, "expectedRevision": String(own.revision), "changes": ["privacyPreset": "balanced"]])
        let updated = try #require(engine.store.profile(withID: own.id))
        #expect(updated.privacyPolicy.retention == .ephemeral)
        #expect(updated.privacyPolicy.presetName == "balanced")
    }
    @Test func privacyPresetIsSavedIntentWithExplicitOutputSchema() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try await engine.call("profile_create", ["name": "Own privacy profile", "changes": ["privacyPreset": "strict"]])
        let intent = try #require(created["privacyPolicyIntent"] as? [String: Any])
        #expect(intent["preset"] as? String == "strict")
        #expect(intent["evidence"] as? String == "saved-intent; not native qualification")
        let properties = try #require(MCPOutputSchemas.schema(for: "profile_get")["properties"] as? [String: Any])
        #expect(properties["privacyPolicyIntent"] != nil)
        let id = try #require(UUID(uuidString: created["id"] as! String))
        #expect(engine.store.profile(withID: id)?.privacyPolicy == .strict)
        #expect(throws: (any Error).self) {
            try BrowserLaunchPolicy.validatePrivacyPolicy(try #require(engine.store.profile(withID: id)))
        }
    }

    @Test func closingIsExplicitInStatusSchemaAndRepeatedStopDoesNotSignalAgain() async throws {
        let fixture = try ManagedClosingFixture(); defer { fixture.cleanup() }
        let engine = MCPProfileManagement(root: fixture.paths.rootDirectory, allowsManagement: true,
            keychain: KeychainStore(backend: Backend(), service: "synthetic-closing", legacyService: nil), processes: fixture.manager)
        fixture.profile = try engine.store.upsert(fixture.profile)
        try fixture.launch(); fixture.inspection = .found
        fixture.manager.stop(profileID: fixture.profile.id)
        let args: [String: Any] = ["profileID": fixture.profile.id.uuidString]
        let stop = try await engine.call("profile_stop", args)
        #expect(stop["stopRequested"] as? Bool == true)
        #expect(stop["processState"] as? String == "closing")
        #expect(fixture.stopCalls == 1)
        let status = try await engine.call("profile_status", args)
        #expect(status["processState"] as? String == "closing")
        for tool in ["profile_status", "profile_stop"] {
            let props = try #require(MCPOutputSchemas.schema(for: tool)["properties"] as? [String: Any])
            #expect(((props["processState"] as? [String: Any])?["enum"] as? [String])?.contains("closing") == true)
        }
        try fixture.finishMain(); try await fixture.waitForMainExit()
        let pending = try await engine.call("profile_stop", args)
        #expect(pending["processState"] as? String == "closing")
        #expect(fixture.stopCalls == 1)
        fixture.inspection = .absent; try await fixture.waitForStopped()
    }
    @Test func fontPolicyIsExplicitRevisionCheckedAndDoesNotClaimRuntimeSupport() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try await engine.call("profile_create", ["name": "Own font profile", "changes": ["startURL": "about:blank", "fontPolicy": "native"]])
        #expect(created["fontPolicy"] as? String == "native")
        let schema = MCPOutputSchemas.schema(for: "profile_get")
        let properties = try #require(schema["properties"] as? [String: Any])
        let required = try #require(schema["required"] as? [String])
        func shapeAccepts(_ response: [String: Any]) -> Bool {
            Set(required).isSubset(of: Set(response.keys)) && Set(response.keys).isSubset(of: Set(properties.keys))
        }
        #expect(shapeAccepts(created))
        var missingPolicy = created; missingPolicy.removeValue(forKey: "fontPolicy")
        #expect(!shapeAccepts(missingPolicy))
        var unknownField = created; unknownField["notAProfileField"] = true
        #expect(!shapeAccepts(unknownField))
        let templates = MCPOutputSchemas.schema(for: "template_list")
        let templateProperties = try #require(templates["properties"] as? [String: Any])
        let list = try #require(templateProperties["templates"] as? [String: Any])
        let item = try #require(list["items"] as? [String: Any])
        #expect(!(item["required"] as? [String] ?? []).contains("fontPolicy"))
        #expect((item["properties"] as? [String: Any])?["fontPolicy"] == nil)

        let id = try #require(UUID(uuidString: created["id"] as! String))
        let before = try #require(engine.store.profile(withID: id)).identity
        var args = request(created); args["changes"] = ["fontPolicy": "system-v1"]
        let enabled = try await engine.call("profile_update", args)
        #expect(enabled["fontPolicy"] as? String == "system-v1")
        await #expect(throws: Error.self) { try await engine.call("profile_update", args) }
        args = request(enabled); args["changes"] = ["name": "Own renamed font profile"]
        let renamed = try await engine.call("profile_update", args)
        #expect(renamed["fontPolicy"] as? String == "system-v1")
        #expect(engine.store.profile(withID: id)?.identity == before)
        #expect(engine.processes.processState(for: id) == .stopped)
        args = request(renamed); args["changes"] = ["fontPolicy": "future-system-v2"]
        await #expect(throws: Error.self) { try await engine.call("profile_update", args) }
        args = request(renamed); args["changes"] = ["fontPolicy": "native"]
        let disabled = try await engine.call("profile_update", args)
        #expect(disabled["fontPolicy"] as? String == "native")
        if BrowserEngine.webkit.isAvailableInBuild {
            let webkit = try await engine.call("profile_create", ["name": "Own WebKit font control", "engine": "webkit"])
            #expect(webkit["fontPolicy"] is NSNull)
            args = request(webkit); args["changes"] = ["fontPolicy": "system-v1"]
            await #expect(throws: Error.self) { try await engine.call("profile_update", args) }
        } else {
            await #expect(throws: Error.self) { try await engine.call("profile_create", ["name": "Unavailable WebKit", "engine": "webkit"]) }
        }
    }
    @Test func webKitMediaPolicyIsRevisionCheckedAndRejectsOtherEngines() async throws {
        guard BrowserEngine.webkit.isAvailableInBuild else { return }
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try await engine.call("profile_create", ["name": "Own media", "engine": "webkit", "changes": ["startURL": "about:blank", "webKitMediaPolicy": "deny"]])
        #expect(created["webKitMediaPolicy"] as? String == "deny")
        var args = request(created); args["changes"] = ["webKitMediaPolicy": "ask"]
        let changed = try await engine.call("profile_update", args)
        #expect(changed["webKitMediaPolicy"] as? String == "ask")
        await #expect(throws: Error.self) { try await engine.call("profile_update", args) }
        args = request(changed); args["changes"] = ["webKitMediaPolicy": "grant"]
        await #expect(throws: Error.self) { try await engine.call("profile_update", args) }
        await #expect(throws: Error.self) { try await engine.call("profile_create", ["name": "Wrong engine", "changes": ["webKitMediaPolicy": "deny"]]) }
    }

    @Test func chromiumOnlyDescriptionsDoNotOfferWebKitLaunch() throws {
        guard !BrowserEngine.webkit.isAvailableInBuild else { return }
        let tools = MCPProfileManagement.definitions(allowsManagement: true)
        let start = try #require(tools.first { $0["name"] as? String == "profile_start" }?["description"] as? String)
        let proxy = try #require(tools.first { $0["name"] as? String == "profile_set_proxy" }?["description"] as? String)
        #expect(start.contains("WebKit profiles cannot be started"))
        #expect(!start.contains("WebKit requires"))
        #expect(proxy.contains("does not prove the browser route"))
    }

    @Test func engineCapabilitiesDoNotAdvertiseUnavailableEngines() {
        for engine in [BrowserEngine.chromium, .webkit] {
            let capabilities = engine.managementCapabilities
            #expect(capabilities.count == 6)
            if !engine.isAvailableInBuild {
                #expect(capabilities.values.allSatisfy { !$0 })
            } else {
                #expect(capabilities["mcpLaunch"] == true)
            }
        }
    }

    @Test func webKitCreationMetadataAndProxyCredentialManagementStayProfileScoped() async throws {
        guard BrowserEngine.webkit.isAvailableInBuild else { return }
        let (root, engine, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let proxyTool = try #require(MCPProfileManagement.definitions(allowsManagement: true)
            .first(where: { $0["name"] as? String == "profile_set_proxy" }))
        let proxyDescription = try #require(proxyTool["description"] as? String)
        #expect(proxyDescription.contains("A WebKit proxy requires the owned runtime"))
        #expect(proxyDescription.contains("launch fails closed without Direct fallback"))
        #expect(!proxyDescription.contains("WebKit applies the system proxy configuration"))
        let created = try await engine.call("profile_create", ["name": "WebKit MCP", "engine": "webkit", "changes": ["startURL": "about:blank"]])
        #expect(created["engine"] as? String == "webkit")
        let capabilities = try #require(created["engineCapabilities"] as? [String: Bool])
        #expect(capabilities == BrowserEngine.webkit.managementCapabilities)
        #expect(capabilities["persistentSiteData"] == true)
        #expect(capabilities["fingerprintConfiguration"] == false && capabilities["mcpLaunch"] == true)
        #expect(capabilities["proxy"] == WebKitProxyFeature.launchEnabled)
        var args = request(created); args["changes"] = ["name": "Renamed WebKit", "tags": ["qa"]]
        var edited = try await engine.call("profile_update", args)
        #expect(edited["engine"] as? String == "webkit")
        args = request(edited); args["changes"] = ["startupMode": "restoreSession"]
        edited = try await engine.call("profile_update", args)
        #expect(edited["startupMode"] as? String == "restoreSession")
        // Management stores proxy configuration and its write-only password;
        // capability flags describe launch support for this build, not storage.
        args = request(edited); args["proxy"] = ["kind": "socks5", "host": "127.0.0.1", "port": 1080,
            "username": "webkit-qa-user", "password": "webkit-qa-secret"]
        edited = try await engine.call("profile_set_proxy", args)
        let webkitID = try #require(UUID(uuidString: edited["id"] as! String))
        #expect(edited["proxyKind"] as? String == "socks5")
        #expect(backend.values[webkitID] == Data("webkit-qa-secret".utf8))
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: edited), as: UTF8.self).contains("webkit-qa-secret"))
        args = request(edited); args["name"] = "WebKit copy"
        let duplicate = try await engine.call("profile_duplicate", args)
        #expect(duplicate["engine"] as? String == "webkit" && duplicate["id"] as? String != edited["id"] as? String)
        await #expect(throws: Error.self) { try await engine.call("profile_start", request(edited)) }
        let id = try #require(UUID(uuidString: edited["id"] as! String))
        #expect(engine.processes.processState(for: id) == .stopped)
    }

    @Test func webKitProxyCanBeCreatedAtomicallyWithoutExposingCredential() async throws {
        guard BrowserEngine.webkit.isAvailableInBuild else { return }
        let (root, engine, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let creation = try #require(MCPProfileManagement.definitions(allowsManagement: true)
            .first(where: { $0["name"] as? String == "profile_create" }))
        let properties = try #require((creation["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        #expect(properties["proxy"] != nil)
        let created = try await engine.call("profile_create", [
            "name": "WebKit proxy at creation", "engine": "webkit",
            "changes": ["startURL": "about:blank"],
            "proxy": ["kind": "http", "host": "127.0.0.1", "port": 45101,
                      "username": "qa-user", "password": "qa-only-password"]
        ])
        let id = try #require(UUID(uuidString: created["id"] as! String))
        let saved = try #require(engine.store.profile(withID: id))
        #expect(saved.proxy?.host == "127.0.0.1")
        #expect(saved.webKitRuntimeGeneration ==
            (WebKitProxyFeature.launchEnabled ? .isolatedV1 : .system))
        #expect(backend.values[id] == Data("qa-only-password".utf8))
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: created), as: UTF8.self)
            .contains("qa-only-password"))
    }

    @Test func webKitSessionAddressesStayOutOfMCPAndConfigurationExport() async throws {
        guard BrowserEngine.webkit.isAvailableInBuild else { return }
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try await engine.call("profile_create", ["name": "Own restore metadata", "engine": "webkit", "changes": ["startURL": "about:blank", "startupMode": "restoreSession"]])
        let id = try #require(UUID(uuidString: created["id"] as! String))
        let marker = "owned-visited-parameter-only"
        let saved = try WebKitSessionSnapshot.capture(profileID: id, urls: ["https://example.com/visited?marker=\(marker)#selected"], selectedIndex: 0)
        try WebKitSessionStore(paths: engine.store.paths).save(saved)
        let result = try await engine.call("profile_get", ["profileID": id.uuidString])
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self).contains(marker))
        #expect(!String(decoding: try Data(contentsOf: engine.store.paths.profilesFile), as: UTF8.self).contains(marker))
        let profile = try #require(engine.store.profile(withID: id))
        let export = try ProfileConfigurationTransferDocument(profiles: [profile])
        #expect(!String(decoding: try JSONEncoder().encode(export), as: UTF8.self).contains(marker))
        var args = request(result); args["changes"] = ["startupMode": "startPage"]
        let off = try await engine.call("profile_update", args)
        #expect(off["startupMode"] as? String == "startPage" && off["warning"] == nil)
        #expect(try WebKitSessionStore(paths: engine.store.paths).load(for: id) == nil)
    }

    @Test func webKitCleanupWarningMeansCommittedEditAndFailedReenableKeepsOff() async throws {
        guard BrowserEngine.webkit.isAvailableInBuild else { return }
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try await engine.call("profile_create", ["name": "Own cleanup warning", "engine": "webkit", "changes": ["startURL": "about:blank", "startupMode": "restoreSession"]])
        let id = try #require(UUID(uuidString: created["id"] as! String)), sessions = WebKitSessionStore(paths: engine.store.paths)
        try sessions.save(.capture(profileID: id, urls: ["about:blank"], selectedIndex: 0))
        let file = root.appendingPathComponent("WebKitSessions/\(id.uuidString.lowercased()).json"), target = root.appendingPathComponent("own-unrelated-canary")
        let canary = Data("untouched own fixture".utf8); try canary.write(to: target)
        try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        var args = request(created); args["changes"] = ["startupMode": "startPage"]
        let off = try await engine.call("profile_update", args)
        #expect(off["startupMode"] as? String == "startPage" && off["warning"] as? String != nil)
        let actual = try await engine.call("profile_get", ["profileID": id.uuidString])
        #expect(actual["revision"] as? String == off["revision"] as? String)
        args = request(actual); args["changes"] = ["startupMode": "restoreSession"]
        await #expect(throws: Error.self) { try await engine.call("profile_update", args) }
        let stillOff = try await engine.call("profile_get", ["profileID": id.uuidString])
        #expect(stillOff["revision"] as? String == off["revision"] as? String && stillOff["startupMode"] as? String == "startPage")
        #expect(try Data(contentsOf: target) == canary)
    }

    @Test func startupModeIsRevisionCheckedAndPersistsWithoutStartingBrowser() async throws {
        let (root, engine, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try await create(engine)
        var args = request(created); args["changes"] = ["startupMode": "restoreSession"]
        let edited = try await engine.call("profile_update", args)
        #expect(edited["startupMode"] as? String == "restoreSession")
        let id = try #require(UUID(uuidString: edited["id"] as! String))
        #expect(engine.store.profile(withID: id)?.startupMode == .restoreSession)
        #expect(engine.processes.processState(for: id) == .stopped)
        await #expect(throws: Error.self) { try await engine.call("profile_update", args) }
        args = request(edited); args["changes"] = ["startupMode": "unrecognized"]
        let before = try Data(contentsOf: engine.store.paths.profilesFile)
        await #expect(throws: Error.self) { try await engine.call("profile_update", args) }
        #expect(try Data(contentsOf: engine.store.paths.profilesFile) == before)
        let read = MCPProfileManagement(root: root, allowsManagement: false)
        await #expect(throws: Error.self) { try await read.call("profile_update", request(edited)) }
    }

    @Test func savedTemplateCreatesFreshProfileWithoutSecretOrBrowserDataCopies() async throws {
        let (root, engine, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await create(engine)
        let folder = try engine.store.createFolder(named: "QA")
        let original = BrowserProfile(name: "Private original", tags: ["qa"], note: "synthetic-private-note", startURL: "https://example.com/qa", startupMode: .restoreSession)
        let template = try UserProfileTemplate(name: "QA template", profile: original, folderID: folder.id)
        _ = try await ManagerLibraryRepository(paths: engine.store.paths).update { $0.templates.append(template) }
        let read = MCPProfileManagement(root: root, allowsManagement: false)
        let list = try await read.call("template_list", [:])
        let rows = try #require(list["templates"] as? [[String: Any]])
        #expect(rows.count == 1 && rows[0]["id"] as? String == template.id.uuidString)
        #expect(Set(rows[0].keys) == ["id", "name", "startURL", "startupMode", "engine", "webKitMediaPolicy", "tags", "folderID"])
        #expect(!(String(decoding: try JSONSerialization.data(withJSONObject: list), as: UTF8.self)).contains("synthetic-private-note"))
        let args: [String: Any] = ["name": "New QA", "templateID": template.id.uuidString,
            "expectedOrganizationRevision": list["organizationRevision"]!]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await read.call("profile_create", args) }
        let first = try await engine.call("profile_create", args)
        let refreshed = try await engine.call("template_list", [:])
        let second = try await engine.call("profile_create", args.merging(["name": "Second", "folderID": NSNull(), "expectedOrganizationRevision": refreshed["organizationRevision"]!, "changes": ["tags": ["other"]]]) { _, new in new })
        let a = try #require(engine.store.profile(withID: UUID(uuidString: first["id"] as! String)!))
        let b = try #require(engine.store.profile(withID: UUID(uuidString: second["id"] as! String)!))
        #expect(a.id != b.id && a.identity != b.identity && a.identity != original.identity)
        #expect(a.startURL == template.startURL && a.tags == template.tags && a.startupMode == .restoreSession)
        #expect(a.note.isEmpty && a.proxy == nil && a.lastLaunchedAt == nil)
        #expect(first["folderID"] as? String == folder.id.uuidString)
        #expect(second["folderID"] is NSNull && b.tags == ["other"])
        #expect(engine.processes.processState(for: a.id) == .stopped)
    }

    @Test func savedTemplateWithInitialNullOrganizationRevisionMatchesSchema() async throws {
        let (root, engine, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try UserProfileTemplate(name: "Fixture", profile: BrowserProfile(name: "Original"), folderID: nil)
        _ = try await ManagerLibraryRepository(paths: engine.store.paths).update { $0.templates.append(template) }
        let definition = try #require(MCPProfileManagement.definitions(allowsManagement: true).first { $0["name"] as? String == "profile_create" })
        let properties = try #require((definition["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        let revision = try #require(properties["expectedOrganizationRevision"] as? [String: Any])
        #expect(Set(try #require(revision["type"] as? [String])) == ["string", "null"])
        let list = try await engine.call("template_list", [:])
        #expect(list["organizationRevision"] is NSNull)
        let result = try await engine.call("profile_create", ["name": "Created", "templateID": template.id.uuidString,
            "expectedOrganizationRevision": list["organizationRevision"]!])
        #expect(result["name"] as? String == "Created")
    }

    @Test func savedTemplateRejectsMissingCorruptAndStaleInputsWithoutPartialWrites() async throws {
        let (root, engine, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ManagerLibraryRepository(paths: engine.store.paths)
        let template = try UserProfileTemplate(name: "Fixture", profile: BrowserProfile(name: "Original"), folderID: UUID())
        _ = try await repository.update { $0.templates.append(template) }
        let list = try await engine.call("template_list", [:])
        #expect((list["templates"] as? [[String: Any]])?.first?["folderID"] is NSNull)
        let args: [String: Any] = ["name": "Fixture", "templateID": template.id.uuidString,
            "expectedOrganizationRevision": list["organizationRevision"]!]
        _ = try engine.store.createFolder(named: "Concurrent change")
        await #expect(throws: Error.self) { try await engine.call("profile_create", args) }
        #expect(engine.store.profiles.isEmpty)
        await #expect(throws: Error.self) { try await engine.call("profile_create", ["name": "Missing", "templateID": UUID().uuidString, "expectedOrganizationRevision": NSNull()]) }
        #expect(engine.store.profiles.isEmpty)
        try engine.store.paths.writePrivateFile(Data("bad-library".utf8), to: root.appendingPathComponent("manager-library.json"))
        await #expect(throws: Error.self) { try await engine.call("template_list", [:]) }
        await #expect(throws: Error.self) { try await engine.call("profile_create", args) }
        #expect(engine.store.profiles.isEmpty)
    }
    final class Backend: KeychainBackend, @unchecked Sendable {
        var values: [UUID: Data] = [:]
        var fail = false
        var failRead = false
        var reads = 0
        struct Failure: Error {}
        func data(service: String, profileID: UUID) throws -> Data? {
            reads += 1
            if failRead { throw Failure() }
            return values[profileID]
        }
        func upsert(_ data: Data, service: String, profileID: UUID) throws { if fail { throw Failure() }; values[profileID] = data }
        func delete(service: String, profileID: UUID) throws { if fail { throw Failure() }; values[profileID] = nil }
    }
    func fixture() throws -> (URL, MCPProfileManagement, Backend) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-management-\(UUID())")
        let paths = AppPaths(rootDirectory: root)
        let backend = Backend()
        let engine = MCPProfileManagement(root: root, allowsManagement: true,
            keychain: KeychainStore(backend: backend, service: "synthetic-mcp", legacyService: nil),
            processes: BrowserProcessManager(paths: paths, processIdentityValidator: { _ in false }, browserDataProcessInspector: { _ in .absent }, allowsExternalProcessSignaling: false))
        return (root, engine, backend)
    }
    func create(_ engine: MCPProfileManagement) async throws -> [String: Any] { try await engine.call("profile_create", ["name": "Synthetic", "changes": ["startURL": "https://example.com", "tags": ["qa"]]]) }
    func request(_ dto: [String: Any]) -> [String: Any] { ["profileID": dto["id"]!, "expectedRevision": dto["revision"]!] }

    @Test func metadataEditKeepsAuthenticatedSOCKSProxyAndWriteOnlyPassword() async throws {
        let (root, engine, backend) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try await create(engine)
        var args = request(created)
        args["proxy"] = ["kind": "socks5", "host": "127.0.0.1", "port": 1080,
                         "username": "qualification-user", "password": "qualification-password"]
        let configured = try await engine.call("profile_set_proxy", args)
        let id = try #require(UUID(uuidString: configured["id"] as! String))
        let original = try #require(engine.store.profile(withID: id)), secrets = backend.values
        args = request(configured); args["changes"] = ["name": "Renamed", "tags": ["ready"], "startURL": "https://example.com/changed"]
        let edited = try await engine.call("profile_update", args)
        let actual = try #require(engine.store.profile(withID: id))
        #expect(actual.name == "Renamed" && actual.tags == ["ready"])
        #expect(actual.proxy == original.proxy && actual.identity == original.identity && backend.values == secrets)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: edited), as: UTF8.self)
        #expect(!encoded.contains("qualification-password") && !encoded.contains("qualification-user"))
        let persisted = try Data(contentsOf: engine.store.paths.profilesFile)
        args = request(edited); args["proxy"] = ["kind": "socks5", "host": "127.0.0.1", "port": 1080, "username": "qualification-user", "password": ""]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_set_proxy", args) }
        #expect(try Data(contentsOf: engine.store.paths.profilesFile) == persisted)
        #expect(engine.store.profile(withID: id)?.proxy == actual.proxy && backend.values == secrets)
    }

    @Test func profilePatchNormalizationAndNoopPreserveUnrelatedFields() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine)
        var args = request(profile); args["changes"] = ["name": " Updated ", "tags": ["qa", "QA", "ready"], "isPinned": true]
        let updated = try await engine.call("profile_update", args)
        #expect(updated["name"] as? String == "Updated")
        #expect(updated["tags"] as? [String] == ["qa", "ready"])
        #expect(updated["startURL"] as? String == "https://example.com")
        args = request(updated); args["changes"] = ["isPinned": true]
        #expect(try await engine.call("profile_update", args)["revision"] as? String == updated["revision"] as? String)
        #expect(try ProfileStore.decodeProfiles(Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)).count == 1)
    }
    @Test func statusObservationRequiresRevisionAndDoesNotClaimStoppedBrowserEvidence() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine), profileID = profile["id"]!
        let legacy = try await engine.call("profile_status", ["profileID": profileID])
        #expect(Set(legacy.keys) == ["profileID", "processState"])
        var args = request(profile); args["includeObservation"] = true
        let observed = try await engine.call("profile_status", args)
        let value = try #require(observed["observation"] as? [String: Any])
        #expect(value["state"] as? String == "unavailable")
        #expect(value["ownership"] as? String == "notOwned")
        #expect(value["chromiumRoute"] as? String == "notObserved")
        #expect(observed["revision"] as? String == profile["revision"] as? String)
        await #expect(throws: MCPProfileManagement.Failure.self) {
            try await engine.call("profile_status", ["profileID": profileID, "includeObservation": true])
        }
        args["includeObservation"] = 1
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_status", args) }
        args["includeObservation"] = true; args["expectedRevision"] = "18446744073709551615"
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_status", args) }
        args = request(profile); args["includeObservation"] = false
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_status", args) }
    }
    @Test func staleProfileRevisionDoesNotOverwriteAndUnknownFieldsFail() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine)
        var args = request(profile); args["changes"] = ["name": "First"]
        _ = try await engine.call("profile_update", args)
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_update", args) }
        args = request(try await engine.call("profile_get", ["profileID": profile["id"]!])); args["changes"] = ["launchFlags": "--unsafe"]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_update", args) }
    }
    @Test func folderRevisionMoveAndRemovalRetainProfileData() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine)
        let initial = try await engine.call("folder_list", [:])
        let folders = try await engine.call("folder_create", ["name": "Project", "expectedOrganizationRevision": initial["organizationRevision"]!])
        let folder = try #require((folders["folders"] as? [[String: Any]])?.first)
        await #expect(throws: ProfileMetadataUndoConflict.self) { try await engine.call("folder_create", ["name": "Stale", "expectedOrganizationRevision": initial["organizationRevision"]!]) }
        var move = request(profile); move["folderID"] = folder["id"]!; move["expectedOrganizationRevision"] = folders["organizationRevision"]!
        let moved = try await engine.call("profile_move", move)
        #expect(moved["folderID"] as? String == folder["id"] as? String)
        let removed = try await engine.call("folder_remove", ["folderID": folder["id"]!, "expectedOrganizationRevision": moved["organizationRevision"]!])
        #expect((removed["folders"] as? [[String: Any]])?.isEmpty == true)
        #expect(try await engine.call("profile_get", ["profileID": profile["id"]!])["folderID"] is NSNull)
        #expect(engine.store.profiles.count == 1)
    }
    @Test func proxyFormatsCredentialsAndRollback() async throws {
        let (root, engine, backend) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = try await create(engine)
        for line in ["synthetic:secret@127.0.0.1:8080", "127.0.0.1:8080:synthetic:secret", "synthetic:secret:127.0.0.1:8080"] {
            var args = request(profile); args["proxyLine"] = line; args["kind"] = "http"
            profile = try await engine.call("profile_set_proxy", args)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: profile), as: UTF8.self)
            #expect(!json.contains("secret")); #expect(!json.contains("127.0.0.1")); #expect(!json.contains("synthetic:"))
        }
        let before = try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)
        backend.fail = true
        var args = request(profile); args["proxy"] = ["kind": "http", "host": "127.0.0.2", "port": 8081, "username": "synthetic", "password": "new-secret"]
        await #expect(throws: (any Error).self) { try await engine.call("profile_set_proxy", args) }
        #expect(try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile) == before)
        backend.fail = false
        args = request(profile); args["proxy"] = NSNull()
        profile = try await engine.call("profile_set_proxy", args)
        #expect(profile["proxyKind"] is NSNull); #expect(backend.values.isEmpty)
    }
    @Test func socksAuthenticationPersistsWithoutExposingSecretAndInvalidURLNeverPersists() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine); let before = try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)
        var args = request(profile); args["proxy"] = ["kind": "socks5", "host": "127.0.0.1", "port": 1080, "username": "synthetic", "password": "secret"]
        let saved = try await engine.call("profile_set_proxy", args)
        #expect(saved["proxyKind"] as? String == "socks5")
        #expect(!String(describing: saved).contains("secret"))
        let after = try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile)
        #expect(after != before)
        args = request(saved); args["changes"] = ["startURL": "file:///etc/passwd"]
        await #expect(throws: MCPProfileManagement.Failure.self) { try await engine.call("profile_update", args) }
        #expect(try Data(contentsOf: AppPaths(rootDirectory: root).profilesFile) == after)
    }
    @Test func duplicateHasFreshIdentityAndNoWebsiteData() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let dto = try await create(engine); let original = try #require(engine.store.profiles.first)
        var args = request(dto); args["name"] = "Copy"
        let copied = try await engine.call("profile_duplicate", args)
        let copy = try #require(engine.store.profile(withID: UUID(uuidString: copied["id"] as! String)))
        #expect(copy.id != original.id); #expect(copy.identity != original.identity); #expect(copy.note.isEmpty)
    }
    @Test func duplicateWithoutAuthenticationDoesNotAccessUnavailableKeychain() async throws {
        let (root, engine, backend) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // A backend that refuses every read detects accidental Keychain access.
        backend.failRead = true
        for kind in BrowserEngine.allCases.map(\.rawValue) {
            let original = try await engine.call("profile_create", ["name": "Direct", "engine": kind])
            var args = request(original); args["name"] = "Direct copy"
            let copied = try await engine.call("profile_duplicate", args)
            #expect(copied["id"] as? String != original["id"] as? String)
            #expect(copied["engine"] as? String == kind)
        }
        let profile = try await create(engine)
        let id = try #require(UUID(uuidString: profile["id"] as! String))
        var configured = try #require(engine.store.profile(withID: id))
        configured.proxy = ProxyConfiguration(kind: .http, host: "127.0.0.1", port: 8080, username: "")
        configured = try engine.store.upsert(configured)
        _ = try await engine.call("profile_duplicate", ["profileID": id.uuidString, "expectedRevision": String(configured.revision), "name": "Unauthenticated copy"])
        #expect(backend.reads == 0)
        // An authenticated profile must still fail safely when its password
        // cannot be read; it must not silently create a credentialless copy.
        configured.proxy?.username = "synthetic"
        configured = try engine.store.upsert(configured)
        let before = try Data(contentsOf: engine.store.paths.profilesFile)
        await #expect(throws: Backend.Failure.self) {
            _ = try await engine.call("profile_duplicate", ["profileID": id.uuidString, "expectedRevision": String(configured.revision), "name": "Must not exist"])
        }
        #expect(backend.reads == 1)
        #expect(try Data(contentsOf: engine.store.paths.profilesFile) == before)
        backend.failRead = false
        backend.values[id] = Data("owned-synthetic-password".utf8)
        let copied = try await engine.call("profile_duplicate", ["profileID": id.uuidString, "expectedRevision": String(configured.revision), "name": "Authenticated copy"])
        let copiedID = try #require(UUID(uuidString: copied["id"] as! String))
        #expect(copiedID != id)
        #expect(backend.values[copiedID] == backend.values[id])
    }
    @Test func refreshPreservesDraftAndLastGoodStateOnCorruption() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let dto = try await create(engine)
        let ui = ProfileStore(paths: AppPaths(rootDirectory: root)); let draft = try #require(ui.profiles.first)
        var args = request(dto); args["changes"] = ["name": "External"]
        _ = try await engine.call("profile_update", args)
        try await ui.refreshExternalMetadata(force: true)
        #expect(ui.profiles.first?.name == "External"); #expect(draft.name == "Synthetic")
        #expect(throws: BrowserProfileRevisionConflictError.self) { try ui.upsert(draft) }
        try Data("broken".utf8).write(to: AppPaths(rootDirectory: root).profilesFile)
        await #expect(throws: (any Error).self) { try await ui.refreshExternalMetadata(force: true) }
        #expect(ui.profiles.first?.name == "External"); #expect(!ui.hasTrustedMetadata)
    }
    @Test func missingMetadataNeverReplacesLastGoodProfileOrFolders() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await create(engine)
        _ = try await engine.call("folder_create", ["name": "Retained", "expectedOrganizationRevision": NSNull()])
        let paths = AppPaths(rootDirectory: root)
        try FileManager.default.removeItem(at: paths.profileOrganizationFile)
        await #expect(throws: (any Error).self) { try await engine.store.refreshExternalMetadata(force: true) }
        #expect(engine.store.organization.folders.count == 1)
        #expect(engine.store.profiles.count == 1)
    }
    @Test func readOnlyInitializationNeverRepairsCorruptPrimaryFromBackup() async throws {
        let (root, engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await create(engine)
        let paths = AppPaths(rootDirectory: root)
        let corrupt = Data("broken synthetic metadata".utf8)
        try corrupt.write(to: paths.profilesFile)
        let reader = MCPProfileManagement(root: root, allowsManagement: false)
        #expect(!reader.store.hasTrustedMetadata)
        #expect(try Data(contentsOf: paths.profilesFile) == corrupt)
        await #expect(throws: MCPProfileManagement.Failure.self) { try await reader.call("folder_list", [:]) }
        try FileManager.default.removeItem(at: paths.profilesFile)
        let missingReader = MCPProfileManagement(root: root, allowsManagement: false)
        await #expect(throws: MCPProfileManagement.Failure.self) { try await missingReader.call("folder_list", [:]) }
        #expect(!FileManager.default.fileExists(atPath: paths.profilesFile.path))
    }

    @Test func readOnlyEmptyWorkspaceRefusesMissingMetadataAndNewSessionRecovers() async throws {
        let (root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root), empty = Data("[]".utf8)
        try paths.writePrivateFile(empty, to: paths.profilesFile)
        let reader = MCPProfileManagement(root: root, allowsManagement: false)
        #expect(reader.store.hasTrustedMetadata)
        _ = try await reader.call("folder_list", [:])
        try FileManager.default.removeItem(at: paths.profilesFile)
        await #expect(throws: (any Error).self) { try await reader.call("folder_list", [:]) }
        #expect(!reader.store.hasTrustedMetadata)
        #expect(!FileManager.default.fileExists(atPath: paths.profilesFile.path))
        try paths.writePrivateFile(empty, to: paths.profilesFile)
        let reopened = MCPProfileManagement(root: root, allowsManagement: false)
        _ = try await reopened.call("folder_list", [:])
        #expect(reopened.store.hasTrustedMetadata)
        #expect(try Data(contentsOf: paths.profilesFile) == empty)
    }

    @Test func managementConfigurationIncludesOnlySelectedServerPermissions() throws {
        var config = MCPConnectionConfiguration(executable: URL(fileURLWithPath: "/private/tmp/QA.app/Contents/MacOS/NeAntik"), dataRoot: URL(fileURLWithPath: "/private/tmp/synthetic-mcp", isDirectory: true))
        #expect(config.arguments.contains(NeAntikLaunchIntent.mcpManagementArgument))
        #expect(NeAntikLaunchIntent.parse(arguments: [config.executable.path] + config.arguments).mode == .mcpManagement(dataRoot: config.dataRoot))
        for tool in MCPProfileManagement.allTools { #expect(config.codexTOML.contains(tool)) }
        #expect(MCPProfileManagement.allTools.count == 18)
        #expect(NeAntikLaunchIntent.parse(arguments: [config.executable.path] + config.arguments + ["--untrusted"]).mode == .invalidControlArguments)
        config.allowsManagement = false
        #expect(!config.arguments.contains(NeAntikLaunchIntent.mcpManagementArgument))
        #expect(!config.codexTOML.contains("profile_create"))
        #expect(NeAntikLaunchIntent.parse(arguments: [config.executable.path] + config.arguments).mode == .mcpStdio(dataRoot: config.dataRoot))
    }

    @Test func folderCorruptionDoesNotPreventStatusOrGracefulStop() async throws {
        let (root, engine, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await create(engine)
        let paths = AppPaths(rootDirectory: root)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: paths.profileOrganizationFile)
        let status = try await engine.call("profile_status", ["profileID": profile["id"]!])
        #expect(status["processState"] as? String == "stopped")
        let stop = try await engine.call("profile_stop", ["profileID": profile["id"]!])
        #expect(stop["stopRequested"] as? Bool == false)
        await #expect(throws: (any Error).self) { try await engine.call("folder_list", [:]) }
        #expect(try Data(contentsOf: paths.profileOrganizationFile) == corrupt)
        try Data("{broken".utf8).write(to: paths.profilesFile)
        await #expect(throws: (any Error).self) { try await engine.call("profile_stop", ["profileID": profile["id"]!]) }
    }

    @Test func readModeAndProtocolRequireExplicitManagementInitialization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MCPManagementSession(root: root, allowsManagement: false)
        func call(_ method: String, _ params: [String: Any] = [:], id: Any? = 1) async throws -> [String: Any]? {
            var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]; if let id { request["id"] = id }
            guard let result = await session.handle(try JSONSerialization.data(withJSONObject: request)) else { return nil }
            return try JSONSerialization.jsonObject(with: result) as? [String: Any]
        }
        #expect(try await call("tools/list")?["error"] != nil)
        _ = try await call("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
        #expect(try await call("tools/list")?["error"] != nil)
        _ = try await call("notifications/initialized", id: nil)
        let denied = try await call("tools/call", ["name": "profile_create", "arguments": ["name": "Denied"]])
        #expect((denied?["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
