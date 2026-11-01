import Foundation
import CoreFoundation

/// Canonical manager operations for one explicitly authorized stdio session.
/// Values from clients are data: no shell, JavaScript, launch flags or paths.
@MainActor
final class MCPProfileManagement {
    let store: ProfileStore
    let processes: BrowserProcessManager
    let keychain: KeychainStore
    let health: ProxyHealthCoordinator
    let allowsManagement: Bool
    private let gui: MCPGUIControlClient

    init(root: URL, allowsManagement: Bool, keychain: KeychainStore? = nil,
         processes: BrowserProcessManager? = nil, guiClient: MCPGUIControlClient? = nil) {
        let paths = AppPaths(rootDirectory: root)
        let environment = NeAntikApplicationEnvironment.resolve(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment)
        self.keychain = keychain ?? KeychainStore.applicationStore(environment: environment, paths: paths)
        store = ProfileStore(paths: paths, readOnlyMetadata: !allowsManagement)
        self.processes = processes ?? BrowserProcessManager(paths: paths)
        health = ProxyHealthCoordinator(fileURL: paths.proxyHealthFile)
        self.allowsManagement = allowsManagement
        gui = guiClient ?? MCPGUIControlClient(root: root)
    }

    func disconnectGUI() { gui.close() }

    enum Failure: Error { case invalid, conflict, unavailable, running, proxyFailed, manualClose, denied, stopRefused, cursor, responseLimit }

    nonisolated static let readTools = ["profile_get", "folder_list", "profile_status", "workspace_query_profiles", "template_list"]
    nonisolated static let writeTools = ["profile_create", "profile_update", "profile_set_proxy", "profile_move", "profile_duplicate", "folder_create", "folder_rename", "folder_remove", "profile_check_proxy", "profile_start", "profile_stop"]
    nonisolated static var allTools: [String] { ["workspace_list_profiles", "workspace_list_profiles_page"] + readTools + writeTools }

    nonisolated static func definitions(allowsManagement: Bool, mediaPolicyEnabled: Bool = WebKitMediaFeature.isEnabled) -> [[String: Any]] {
        let text: [String: Any] = ["type": "string"]
        let uuid: [String: Any] = ["type": "string", "format": "uuid"]
        let revision: [String: Any] = ["type": "string", "pattern": "^(0|[1-9][0-9]*)$"]
        let optionalUUID: [String: Any] = ["type": ["string", "null"]]
        let changes: [String: Any] = ["type": "object", "additionalProperties": false, "properties": WebKitMediaFeature.visibleFields([
            "privacyPreset": ["type": "string", "enum": ["legacy", "balanced", "strict"], "description": "Changes privacy policy only. Omitted fontPolicy is preserved on update; specify system-v1 explicitly to match the GUI's balanced/strict font selection."], "name": text, "startURL": text, "startupMode": ["type": "string", "enum": BrowserStartupMode.allCases.map(\.rawValue)], "fontPolicy": ["type": "string", "enum": ["native", "system-v1"]], "webKitMediaPolicy": ["type": "string", "enum": WebKitMediaPolicy.allCases.map(\.rawValue)], "tags": ["type": "array", "maxItems": 8, "items": text],
            "note": text, "isPinned": ["type": "boolean"], "isArchived": ["type": "boolean"], "colorHex": text, "symbolName": text], enabled: mediaPolicyEnabled)]
        let proxyFields: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["kind", "host", "port"], "properties": [
            "kind": ["type": "string", "enum": ["http", "https", "socks5"]], "host": text,
            "port": ["type": "integer", "minimum": 1, "maximum": 65535], "username": text, "password": text]]
        let profileCreateDescription: String
        #if NEANTIK_CHROMIUM_ONLY
        profileCreateDescription = "Create a Chromium profile without starting it. Optional templateID uses saved Chromium template metadata with fresh identity; requires expectedOrganizationRevision from template_list. Proxy fields and proxyLine use the same write-only credential rules as profile_set_proxy."
        #else
        profileCreateDescription = "Create a persistent profile without starting it. Optional templateID uses saved safe metadata with fresh identity; requires expectedOrganizationRevision from template_list. Explicit changes/folder override template values. Optional proxy fields, proxyLine or proxy:null use the same write-only credential rules as profile_set_proxy. A new WebKit proxy profile selects the owned runtime only when that route is enabled; a Direct WebKit profile selects system WebKit. No automatic retry: a repeat creates another profile."
        #endif
        let specs: [(String, String, [String: Any], [String])] = [
            ("template_list", "Read saved user templates (maximum50), safe start pages and tags. No credentials, notes, identity or BrowserData. Missing project folders resolve to unfiled. Use templateID plus this organizationRevision with profile_create; creation never starts a browser.", [:], []),
            ("profile_get", "Read profile revision, start page, organization and requested fontPolicy (not applied-state proof). system-v1 is Chromium-only and needs the exact qualified runtime at launch. Proxy endpoint, credentials and note excluded.", ["profileID": uuid], ["profileID"]),
            ("folder_list", "Read up to100 project folders and organizationRevision. Pass nextCursor unchanged; restart on organization change.", ["limit": ["type": "integer", "minimum": 1, "maximum": 100], "cursor": text], []),
            ("workspace_query_profiles", "Find profiles by name, tags and project without reading private notes. Tags use AND; omitted archived means active only. folderID:null means unfiled, omission means any. Cursor is tied to filters and snapshot. Process state remains unverified.", MCPWorkspaceQuery.properties, []),
            ("profile_status", "Management mode reconciles profile ownership; external sessions require manual close. Read-only mode does not reconcile or clear data and returns externalUnverified, which does not mean stopped. Optional includeObservation:true requires expectedRevision and observes only this session's verified owned browser, launch configuration and readiness for graceful close. Never returns page content, credentials, PID, paths or proof of Chromium network route.", ["profileID": uuid, "includeObservation": ["type": "boolean"], "expectedRevision": revision], ["profileID"]),
            ("profile_create", profileCreateDescription, ["name": text, "engine": ["type": "string", "enum": BrowserEngine.allCases.map(\.rawValue)], "changes": changes, "templateID": uuid, "folderID": optionalUUID, "expectedOrganizationRevision": optionalUUID, "proxy": ["anyOf": [proxyFields, ["type": "null"]]], "proxyLine": text, "kind": ["type": "string", "enum": ["http", "https", "socks5"]], "order": ["type": "string", "enum": ["automatic", "credentialsFirst", "endpointFirst"]]], ["name"]),
            ("profile_update", "Patch an existing stopped profile; omitted fields stay unchanged. fontPolicy:native|system-v1 explicitly selects Chromium font handling; system-v1 needs the qualified runtime at launch, not just a profile seed. Read its revision first.", ["profileID": uuid, "expectedRevision": revision, "changes": changes], ["profileID", "expectedRevision", "changes"]),
            ("profile_set_proxy", BrowserEngine.webkit.isAvailableInBuild ? "Configure/disable proxy settings on a stopped profile. Use proxy:null, proxy fields, or proxyLine with kind/order. Password is write-only and may enter AI history. Chromium authentication uses its per-profile local relay. A WebKit proxy requires the owned runtime; switching an existing WebKit profile between Direct and proxy is refused because those runtimes have separate site data. Create a new profile for that change. When the WebKit route is disabled, settings may be saved but launch fails closed without Direct fallback. HTTPS proxy certificates are verified before authentication when the supported route is enabled. A saved proxy and preflight result do not prove the browser route." : "Configure or disable proxy settings on a stopped Chromium profile. Use proxy:null, proxy fields, or proxyLine with kind/order. Password is write-only and may enter AI history. Chromium authentication uses its per-profile local relay. HTTPS proxy certificates are verified before authentication. A saved proxy or preflight result does not prove the browser route.", ["profileID": uuid, "expectedRevision": revision, "proxy": ["anyOf": [proxyFields, ["type": "null"]]], "proxyLine": text, "kind": ["type": "string", "enum": ["http", "https", "socks5"]], "order": ["type": "string", "enum": ["automatic", "credentialsFirst", "endpointFirst"]]], ["profileID", "expectedRevision"]),
            ("profile_move", "Move stopped profile to folder/project or null (unfiled). Both revisions protect concurrent changes.", ["profileID": uuid, "expectedRevision": revision, "folderID": optionalUUID, "expectedOrganizationRevision": optionalUUID], ["profileID", "expectedRevision", "folderID", "expectedOrganizationRevision"]),
            ("profile_duplicate", "Copy configuration into a fresh identity; never copy cookies, notes or BrowserData. Copies proxy password via local Keychain without returning it.", ["profileID": uuid, "expectedRevision": revision, "name": text], ["profileID", "expectedRevision", "name"]),
            ("folder_create", "Create a project folder.", ["name": text, "expectedOrganizationRevision": optionalUUID], ["name", "expectedOrganizationRevision"]),
            ("folder_rename", "Rename a project folder using its current organization revision.", ["folderID": uuid, "name": text, "expectedOrganizationRevision": optionalUUID], ["folderID", "name", "expectedOrganizationRevision"]),
            ("folder_remove", "Remove only the folder; retain all profiles and website data, moving them to unfiled.", ["folderID": uuid, "expectedOrganizationRevision": optionalUUID], ["folderID", "expectedOrganizationRevision"]),
            ("profile_check_proxy", BrowserEngine.webkit.isAvailableInBuild ? "Check proxy availability using bounded preflight diagnostics; does not qualify the Chromium or WebKit window route and does not change profile context." : "Check proxy availability using bounded preflight diagnostics; this does not prove the browser route and does not change profile context.", ["profileID": uuid, "expectedRevision": revision], ["profileID", "expectedRevision"]),
            ("profile_start", BrowserEngine.webkit.isAvailableInBuild ? "Start Chromium via the normal pipeline, no direct fallback. WebKit requires an already open signed NeAntik GUI, enabled MCP WebKit access and explicit approval of this connection and selected profiles. First request asks for consent; retry intentionally after approval. Disconnect leaves browsers open. Never starts the GUI automatically." : "Start a Chromium profile via the normal pipeline without direct fallback. Existing WebKit profiles cannot be started in this build.", ["profileID": uuid, "expectedRevision": revision], ["profileID", "expectedRevision"]),
            ("profile_stop", "Request graceful close of a browser owned by this live session. Poll profile_status; pending is not stopped.", ["profileID": uuid], ["profileID"])
        ]
        return specs.filter { allowsManagement || readTools.contains($0.0) }.map { name, description, properties, required in
            ["name": name, "title": name.replacingOccurrences(of: "_", with: " "), "description": description,
             "outputSchema": MCPOutputSchemas.schema(for: name),
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readTools.contains(name), "destructiveHint": !readTools.contains(name),
                             "idempotentHint": readTools.contains(name), "openWorldHint": ["profile_start", "profile_check_proxy"].contains(name)]]
        }
    }

    func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard let definition = Self.definitions(allowsManagement: true).first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: Any],
              Set(args.keys).isSubset(of: Set(properties.keys)),
              (schema["required"] as? [String] ?? []).allSatisfy({ args[$0] != nil }) else { throw Failure.invalid }
        guard Self.readTools.contains(name) || allowsManagement else { throw Failure.denied }
        let lifecycleOnly = name == "profile_status" || name == "profile_stop"
        if !allowsManagement, (!store.hasTrustedMetadata || (!lifecycleOnly && !store.hasTrustedOrganization)) { throw Failure.unavailable }
        if name == "profile_check_proxy" { ProxyAuditPhase.mark(.metadataInitialBegin) }
        do {
            try await store.refreshExternalMetadata()
        } catch {
            // These operations use independently validated profile IDs and process
            // ownership, never folder assignments. A broken sidecar must not
            // prevent gracefully closing a browser owned by this session.
            guard lifecycleOnly, store.hasTrustedMetadata, !store.hasTrustedOrganization else { throw error }
        }
        if name == "profile_check_proxy" { ProxyAuditPhase.mark(.metadataInitialDone) }
        guard store.hasTrustedMetadata, lifecycleOnly || store.hasTrustedOrganization else { throw Failure.unavailable }
        try Task.checkCancellation()
        if name == "template_list" {
            let library = try await ManagerLibraryRepository(paths: store.paths).load()
            try Task.checkCancellation()
            try await store.refreshExternalMetadata(force: true)
            try Task.checkCancellation()
            let availableTemplates = library.templates.filter { ($0.engine ?? .chromium).isAvailableInBuild }
            return ["templates": availableTemplates.map { template -> [String: Any] in
                WebKitMediaFeature.visibleFields(["id": template.id.uuidString, "name": template.name, "startURL": template.startURL, "startupMode": (template.startupMode ?? .startPage).rawValue, "engine": (template.engine ?? .chromium).rawValue, "webKitMediaPolicy": (template.webKitMediaPolicy ?? .ask).rawValue,
                 "tags": template.tags, "folderID": template.folderID.flatMap {
                     store.organization.folder(withID: $0)?.id.uuidString
                 } as Any? ?? NSNull()])
            }, "count": availableTemplates.count,
            "organizationRevision": store.organization.mutationRevision?.uuidString as Any? ?? NSNull()]
        }
        if name == "workspace_query_profiles" {
            let query = try MCPWorkspaceQuery(arguments: args)
            let profiles = store.profiles, organization = store.organization
            return try await MCPWorkspaceQuery.executeCancellable {
                try query.page(profiles: profiles, organization: organization)
            }
        }
        if name == "folder_list" { return try folderPage(args) }
        if name.hasPrefix("folder_") {
            let orgRevision = try organizationRevision(args)
            let affectedID: UUID
            var affected: ProfileFolder?
            switch name {
            case "folder_create":
                affected = try store.createFolder(named: string(args, "name"), expectedOrganizationRevision: .some(orgRevision)); affectedID = affected!.id
            case "folder_rename":
                affectedID = try id(args, "folderID")
                affected = try store.renameFolder(withID: affectedID, to: string(args, "name"), expectedOrganizationRevision: .some(orgRevision))
            case "folder_remove":
                affectedID = try id(args, "folderID")
                _ = try store.deleteFolder(withID: affectedID, expectedOrganizationRevision: .some(orgRevision))
            default: throw Failure.invalid
            }
            // Mutation receipts contain only the affected folder, never the entire
            // catalog: a large workspace cannot turn a committed write into an error.
            return ["organizationRevision": store.organization.mutationRevision?.uuidString as Any? ?? NSNull(),
                    "affectedFolderID": affectedID.uuidString,
                    "folders": affected.map { [["id": $0.id.uuidString, "name": $0.name]] } ?? []]
        }
        if name == "profile_create" {
            var template: UserProfileTemplate?
            if args["templateID"] != nil {
                let templateID = try id(args, "templateID")
                let library = try await ManagerLibraryRepository(paths: store.paths).load()
                try Task.checkCancellation()
                guard let found = library.templates.first(where: { $0.id == templateID }),
                      args["expectedOrganizationRevision"] != nil else { throw Failure.invalid }
                template = found
                try await store.refreshExternalMetadata(force: true)
                try Task.checkCancellation()
            }
            let requestedName = try string(args, "name")
            var profile = template?.makeProfile() ?? BrowserProfile(name: requestedName)
            if args["engine"] != nil {
                guard let engine = BrowserEngine(rawValue: try string(args, "engine")) else { throw Failure.invalid }
                profile.engine = engine
            }
            if profile.engine == .chromium {
                if template == nil { profile.privacyPolicy = .balanced }
                if profile.privacyPolicy != .legacy { profile.fontPolicy = .systemV1 }
            }
            guard profile.engine.isAvailableInBuild else { throw Failure.invalid }
            profile.name = requestedName
            try apply(args["changes"] as? [String: Any] ?? [:], to: &profile)
            let hasProxyArgument = args["proxy"] != nil || args["proxyLine"] != nil || args["kind"] != nil || args["order"] != nil
            let proxyDraft = hasProxyArgument ? try parseProxy(args) : nil
            profile.proxy = proxyDraft?.configuration
            profile.webKitRuntimeGeneration = WebKitProfilePolicy.runtimeGenerationForSave(
                engine: profile.engine, proxy: profile.proxy,
                previous: profile.webKitRuntimeGeneration,
                ownedProxyAvailable: WebKitProxyFeature.launchEnabled)
            try validate(profile, password: proxyDraft?.password ?? "")
            if let value = args["changes"], !(value is [String: Any]) { throw Failure.invalid }
            let folder = args["folderID"] != nil ? try nullableID(args, "folderID") : template?.folderID.flatMap {
                store.organization.folder(withID: $0)?.id
            }
            let expected: UUID?? = args["expectedOrganizationRevision"] == nil ? nil : .some(try organizationRevision(args))
            if folder != nil && expected == nil { throw Failure.invalid }
            let saved = try store.upsert(profile, toFolderID: folder, expectedOrganizationRevision: expected,
                afterPersist: { committed in
                    if let proxyDraft {
                        try self.keychain.updateProxyPasswordForProfileEdit(proxyDraft.password, profileID: committed.id)
                    }
                })
            store.managerLibrary.record(.create, .succeeded)
            return dto(saved)
        }
        let profileID = try id(args, "profileID")
        guard var profile = store.profile(withID: profileID) else { throw Failure.unavailable }
        if name == "profile_get" { return dto(profile) }
        if name == "profile_status" {
            let includeObservation: Bool
            if let value = args["includeObservation"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.invalid }
                includeObservation = number.boolValue
            } else { includeObservation = false }
            if !includeObservation && args["expectedRevision"] != nil { throw Failure.invalid }
            let expected: UInt64? = includeObservation ? try revision(args) : nil
            if let expected, profile.revision != expected { throw Failure.conflict }
            // Reconciliation can retire leases and clear pending ephemeral data.
            // A read-only MCP session has no authority for either side effect.
            // Until a separate non-mutating process observer is available, do
            // not turn the absence of an observation into a stopped claim.
            if !allowsManagement {
                var result: [String: Any] = ["profileID": profileID.uuidString, "processState": "externalUnverified"]
                if includeObservation {
                    result["revision"] = String(profile.revision)
                    result["observation"] = BrowserSessionObservation.unavailable(.unverified).mcpValue
                }
                return result
            }
            if profile.engine == .webkit, gui.ownedProfiles.contains(profileID) {
                let reply = try await gui.lifecycle(.status, profileID: profileID)
                var result: [String: Any] = ["profileID": profileID.uuidString, "processState": Self.guiProcessState(reply), "webKitState": reply.state!.rawValue]
                if includeObservation {
                    try await store.refreshExternalMetadata(force: true)
                    try Task.checkCancellation()
                    guard store.hasTrustedMetadata, let current = store.profile(withID: profileID), current.revision == expected else { throw Failure.conflict }
                    result["revision"] = String(current.revision)
                    result["observation"] = BrowserSessionObservation.unavailable(.thisSession).mcpValue
                }
                return result
            }
            try await observe(profileID)
            guard includeObservation else {
                return ["profileID": profileID.uuidString, "processState": status(profileID)]
            }
            var observation = try await processes.observeManagedBrowserSession(profileID: profileID, expectedRevision: expected)
            do { try await store.refreshExternalMetadata() }
            catch {
                guard store.hasTrustedMetadata, !store.hasTrustedOrganization else { throw error }
            }
            try Task.checkCancellation()
            guard store.hasTrustedMetadata,
                  let expected, let current = store.profile(withID: profileID), current.revision == expected
            else { throw Failure.conflict }
            if observation.state == .observed {
                if !(try await processes.revalidateManagedBrowserObservation(observation, profileID: profileID, expectedProfile: current)) {
                    observation = .unavailable(.unverified)
                }
                guard store.profile(withID: profileID)?.revision == expected, store.hasTrustedMetadata else { throw Failure.conflict }
            }
            return ["profileID": profileID.uuidString, "processState": status(profileID),
                    "revision": String(current.revision), "observation": observation.mcpValue]
        }
        if name == "profile_stop" {
            if profile.engine == .webkit, gui.ownedProfiles.contains(profileID) {
                let reply = try await gui.lifecycle(.stop, profileID: profileID)
                return ["profileID": profileID.uuidString, "stopRequested": reply.stopRequested!,
                    "processState": Self.guiProcessState(reply), "webKitState": reply.state!.rawValue]
            }
            try await observe(profileID)
            let state = processes.processState(for: profileID)
            guard state == .managed || state == .closing || state == .stopped else { throw Failure.manualClose }
            if state == .managed {
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    if processes.processState(for: profileID) != .managed || processes.managedBrowserReadyForQuit(profileID: profileID) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                if processes.processState(for: profileID) == .managed {
                    guard processes.managedBrowserReadyForQuit(profileID: profileID) else { throw Failure.stopRefused }
                    processes.lastError = nil
                    processes.stop(profileID: profileID)
                    guard processes.lastError == nil else { throw Failure.stopRefused }
                }
            }
            return ["profileID": profileID.uuidString, "stopRequested": state == .managed || state == .closing, "processState": status(profileID)]
        }
        let expected = try revision(args)
        guard profile.revision == expected else { throw Failure.conflict }
        switch name {
        case "profile_start": return try await launch(profile)
        case "profile_check_proxy":
            ProxyAuditPhase.mark(.stoppedVerifyBegin)
            try processes.withVerifiedStoppedProfileOperation(profileID: profileID) {}
            ProxyAuditPhase.mark(.stoppedVerifyDone)
            guard let proxy = profile.proxy else { throw Failure.invalid }
            ProxyAuditPhase.mark(.healthRunBegin)
            let state = try await health.run(profile: profile, operationWithCurrentIdentity: { previous in
                try await ProfileProxyOperations(store: self.store, keychain: self.keychain, invalidateObservation: { _ in })
                    .commit(profileID: profileID, expectedProxy: proxy, expectedRevision: expected, previous: previous, commitsLaunchContext: false)
            })
            ProxyAuditPhase.mark(.healthRunDone)
            return ["profileID": profileID.uuidString, "outcome": state?.latestAttempt.outcome.userSummary ?? "No committed observation", "chromiumRoute": "unverified"]
        default: break
        }
        store.postCommitWarning = nil
        let result = try processes.withVerifiedStoppedProfileOperation(profileID: profileID) {
            switch name {
            case "profile_update":
                guard let changes = args["changes"] as? [String: Any], !changes.isEmpty else { throw Failure.invalid }
                let original = profile
                try apply(changes, to: &profile); try validateMetadata(profile)
                if original != profile { profile = try store.upsert(profile) }
            case "profile_move":
                profile = try store.upsert(profile, toFolderID: nullableID(args, "folderID"), expectedOrganizationRevision: .some(organizationRevision(args)))
            case "profile_set_proxy":
                let draft = try parseProxy(args)
                profile.proxy = draft?.configuration
                let desiredWebKitRuntime = WebKitProfilePolicy.runtimeGenerationForSave(
                    engine: profile.engine, proxy: profile.proxy,
                    previous: profile.webKitRuntimeGeneration,
                    ownedProxyAvailable: WebKitProxyFeature.launchEnabled)
                guard profile.webKitRuntimeGeneration == desiredWebKitRuntime else { throw Failure.invalid }
                if profile.engine == .chromium {
                    profile.identity = profile.identity.replacingProxyContext(timezoneIdentifier: nil, localeIdentifier: nil, evidence: nil)
                }
                try validate(profile, password: draft?.password ?? "")
                profile = try store.upsert(profile, afterPersist: { saved in
                    try self.keychain.updateProxyPasswordForProfileEdit(draft?.password, profileID: saved.id)
                })
            case "profile_duplicate":
                let password = try keychain.configuredProxyPassword(for: profile)
                var copy = profile.duplicated(); copy.name = try string(args, "name"); try validate(copy, password: password ?? "")
                profile = try store.duplicateProfile(profile, name: copy.name, afterPersist: { saved in
                    if let password { try self.keychain.updateProxyPasswordForProfileEdit(password, profileID: saved.id) }
                })
            default: throw Failure.invalid
            }
            var committed = dto(profile)
            if let warning = store.postCommitWarning { committed["warning"] = warning }
            return committed
        }
        if name == "profile_set_proxy" {
            do { try await health.remove(profileID: profileID) }
            catch { var committed = result; committed["warning"] = "Proxy configuration saved; old diagnostic cleanup unavailable. Re-read current profile."; return committed }
        }
        return result
    }

    private func launch(_ initial: BrowserProfile) async throws -> [String: Any] {
        if initial.engine == .webkit {
            guard initial.engine.isAvailableInBuild else {
                throw WebKitProfileError.unsupported("WebKit выключен в этой версии NeAntik. Профиль и его данные сохранены; запускайте его в сборке с поддержкой WebKit.")
            }
            guard allowsManagement else { throw Failure.denied }
            let reply = try await gui.start(profileID: initial.id, revision: initial.revision)
            return ["profileID": initial.id.uuidString, "processState": "managed", "revision": reply.revision!]
        }
        try await observe(initial.id)
        guard processes.processState(for: initial.id) == .stopped else { throw Failure.running }
        let locator = BrowserRuntimeLocator()
        guard let runtime = await Task.detached(priority: .userInitiated, operation: { locator.preferredRuntime() }).value else { throw Failure.unavailable }
        let preflight = await Task.detached { BrowserRuntimePreflightValidator.validate(runtime) }.value
        guard preflight.isReady else { throw Failure.unavailable }
        try Task.checkCancellation()
        var admissionToken: UUID?
        for attempt in 0...20 {
            try Task.checkCancellation()
            do { admissionToken = try ManagerLaunchAdmission.shared.begin(profileID: initial.id); break }
            catch ManagerLaunchAdmissionError.busy {
                if attempt == 20 { throw ManagerLaunchAdmissionError.busy }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let token = admissionToken else { throw ManagerLaunchAdmissionError.busy }
        var launched = false
        defer { ManagerLaunchAdmission.shared.finish(token: token, launched: launched) }
        try store.validateLaunchSnapshot(initial)
        var profile = initial
        var receipt: BrowserLaunchPreparationReceipt?
        if let proxy = initial.proxy {
            let state = try await health.run(profile: initial, operationWithCurrentIdentity: { previous in
                try await ProfileProxyOperations(store: self.store, keychain: self.keychain, invalidateObservation: { _ in })
                    .commit(profileID: initial.id, expectedProxy: proxy, expectedRevision: initial.revision, previous: previous, commitsLaunchContext: true)
            })
            guard state?.latestAttempt.outcome == .succeeded, let current = store.profile(withID: initial.id), current.proxy == proxy else { throw Failure.proxyFailed }
            profile = current
            let currentHealth = health.state(for: current)
            guard BrowserLaunchPreparationPolicy.resolve(profile: current, proxyHealth: currentHealth) == .launchImmediately else { throw Failure.proxyFailed }
            receipt = BrowserLaunchPreparationPolicy.receipt(profile: current, proxyHealth: currentHealth)
        }
        try Task.checkCancellation()
        try await processes.launchUserProfile(profile: profile, runtime: runtime, preparationReceipt: receipt, keychain: keychain)
        guard let launchMetadata = store.markLaunchedWithReceipt(profile.id) else { processes.stop(profileID: profile.id); throw Failure.unavailable }
        processes.recordManagedLaunchMetadata(from: profile, to: launchMetadata.recorded)
        await health.recordLaunchMetadata(from: profile, receipt: launchMetadata)
        launched = true
        store.managerLibrary.record(.launch, .succeeded)
        return ["profileID": profile.id.uuidString, "processState": status(profile.id), "revision": String(store.profile(withID: profile.id)?.revision ?? profile.revision)]
    }

    private func apply(_ changes: [String: Any], to profile: inout BrowserProfile) throws {
        guard Set(changes.keys).isSubset(of: ["name", "startURL", "startupMode", "privacyPreset", "fontPolicy", "webKitMediaPolicy", "tags", "note", "isPinned", "isArchived", "colorHex", "symbolName"]) else { throw Failure.invalid }
        for (key, value) in changes {
            switch key {
            case "name": profile.name = try string(changes, key).trimmingCharacters(in: .whitespacesAndNewlines)
            case "startURL": guard let url = BrowserLaunchBuilder.validatedStartURL(try string(changes, key)) else { throw Failure.invalid }; profile.startURL = url.absoluteString
            case "startupMode": guard let mode = BrowserStartupMode(rawValue: try string(changes, key)) else { throw Failure.invalid }; profile.startupMode = mode
            case "privacyPreset":
                guard profile.engine == .chromium,
                      let policy = profile.privacyPolicy.applyingPreset(try string(changes, key)) else { throw Failure.invalid }
                profile.privacyPolicy = policy
            case "fontPolicy": guard profile.engine == .chromium, let policy = BrowserFontPolicy(rawValue: try string(changes, key)) else { throw Failure.invalid }; profile.fontPolicy = policy
            case "webKitMediaPolicy": guard WebKitMediaFeature.isEnabled, profile.engine == .webkit, let policy = WebKitMediaPolicy(rawValue: try string(changes, key)) else { throw Failure.invalid }; profile.webKitMediaPolicy = policy
            case "note": guard let note = BrowserProfile.normalizedNote(try string(changes, key)) else { throw Failure.invalid }; profile.note = note
            case "tags": guard let tags = value as? [String], let normalized = BrowserProfile.normalizedTags(tags) else { throw Failure.invalid }; profile.tags = normalized
            case "isPinned", "isArchived": guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.invalid }; if key == "isPinned" { profile.isPinned = number.boolValue } else { profile.isArchived = number.boolValue }
            case "colorHex": profile.colorHex = try string(changes, key)
            case "symbolName": profile.symbolName = try string(changes, key)
            default: throw Failure.invalid
            }
        }
    }

    /// Metadata edits retain the existing proxy and never read its write-only
    /// password. Credential admission belongs to set-proxy/duplicate/launch.
    private func validateMetadata(_ profile: BrowserProfile) throws {
        if profile.engine == .webkit { try WebKitProfilePolicy.validateConfiguration(profile) }
        guard profile.normalizedForPersistence() != nil,
              ProfileEditorValidation.firstIssue(name: profile.name, tags: profile.tags,
                  note: profile.note, startURL: profile.startURL, usesProxy: false,
                  proxyKind: .http, proxyHost: "", proxyPort: "0", proxyUsername: "") == nil
        else { throw Failure.invalid }
    }

    private func validate(_ profile: BrowserProfile, password: String = "") throws {
        if profile.engine == .webkit { try WebKitProfilePolicy.validateConfiguration(profile) }
        guard profile.normalizedForPersistence() != nil else { throw Failure.invalid }
        if ProfileEditorValidation.firstIssue(name: profile.name, tags: profile.tags, note: profile.note, startURL: profile.startURL,
            usesProxy: profile.proxy != nil, proxyKind: profile.proxy?.kind ?? .http, proxyHost: profile.proxy?.host ?? "", proxyPort: String(profile.proxy?.port ?? 0), proxyUsername: profile.proxy?.username ?? "", proxyPassword: password) != nil { throw Failure.invalid }
    }
    private func parseProxy(_ args: [String: Any]) throws -> ProxyImportDraft? {
        if let line = args["proxyLine"] {
            guard args["proxy"] == nil, let line = line as? String, let kind = ProxyKind(rawValue: try string(args, "kind")) else { throw Failure.invalid }
            guard args["order"] == nil || args["order"] is String else { throw Failure.invalid }
            let order = ProxyImportOrder(rawValue: args["order"] as? String ?? "automatic")
            guard let order else { throw Failure.invalid }
            return try ProxyImportParser.parse(line, kind: kind, order: order)
        }
        guard args["kind"] == nil, args["order"] == nil, let value = args["proxy"] else { throw Failure.invalid }
        if value is NSNull { return nil }
        guard let fields = value as? [String: Any], Set(fields.keys).isSubset(of: ["kind", "host", "port", "username", "password"]), let kind = ProxyKind(rawValue: try string(fields, "kind")), let number = fields["port"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue), (1...65535).contains(number.intValue) else { throw Failure.invalid }
        let configuration = ProxyConfiguration(kind: kind, host: try string(fields, "host"), port: number.intValue, username: fields["username"] == nil ? "" : try string(fields, "username"))
        let password = fields["password"] == nil ? "" : try string(fields, "password")
        return ProxyImportDraft(configuration: configuration, password: password)
    }
    private func dto(_ profile: BrowserProfile) -> [String: Any] {
        WebKitMediaFeature.visibleFields(["id": profile.id.uuidString, "revision": String(profile.revision), "name": profile.name, "startURL": profile.startURL, "startupMode": profile.startupMode.rawValue, "fontPolicy": profile.engine == .chromium ? profile.fontPolicy.rawValue as Any : NSNull(), "engine": profile.engine.rawValue, "webKitMediaPolicy": profile.engine == .webkit ? profile.webKitMediaPolicy.rawValue as Any : NSNull(),
         "engineCapabilities": profile.engine.managementCapabilities,
         "privacyPolicyIntent": profile.privacyPolicy.safeIntent,
         "tags": profile.tags, "isPinned": profile.isPinned, "isArchived": profile.isArchived,
         "colorHex": profile.colorHex, "symbolName": profile.symbolName, "folderID": store.folderID(forProfileID: profile.id)?.uuidString as Any? ?? NSNull(),
         "organizationRevision": store.organization.mutationRevision?.uuidString as Any? ?? NSNull(), "proxyKind": profile.proxy?.kind.rawValue as Any? ?? NSNull()])
    }
    private func folderPage(_ args: [String: Any]) throws -> [String: Any] {
        let query = try MCPWorkspaceQuery(arguments: args)
        let revision = store.organization.mutationRevision?.uuidString ?? "initial"
        let offset = try query.offset(snapshot: revision)
        let folders = store.organization.folders
        guard offset <= folders.count else { throw Failure.cursor }
        let end = min(offset + query.limit, folders.count)
        return ["organizationRevision": store.organization.mutationRevision?.uuidString as Any? ?? NSNull(),
                "folders": folders[offset..<end].map { ["id": $0.id.uuidString, "name": $0.name] },
                "count": end - offset, "totalCount": folders.count,
                "nextCursor": end < folders.count ? query.cursor(snapshot: revision, offset: end) as Any : NSNull()]
    }
    /// Production inventory is asynchronous. A newly queued check is not proof
    /// that a stopped browser is running. Await it, bounded and cancellable.
    private func observe(_ profileID: UUID) async throws {
        if [.managed, .closing].contains(processes.processState(for: profileID)) { return }
        processes.reconcile(profiles: store.profiles)
        for _ in 0..<100 {
            try Task.checkCancellation()
            if processes.processState(for: profileID) != .checking { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func guiProcessState(_ reply: MCPGUIControlProtocol.Reply) -> String {
        switch reply.state {
        case .managed, .stopPending, .saveFailed: "managed"
        case .stopped: "stopped"
        default: "externalManualOnly"
        }
    }
    private func status(_ id: UUID) -> String {
        switch processes.processState(for: id) {
        case .managed: "managed"
        case .stopped: "stopped"
        case .externalManualOnly, .externalVerified: "externalManualOnly"
        case .checking: "checking"
        case .closing: "closing"
        case .externalUnverified: "externalUnverified"
        case .recoveryRequired: "recoveryRequired"
        }
    }
    private func string(_ args: [String: Any], _ key: String) throws -> String { guard let value = args[key] as? String else { throw Failure.invalid }; return value }
    private func id(_ args: [String: Any], _ key: String) throws -> UUID { guard let value = UUID(uuidString: try string(args, key)) else { throw Failure.invalid }; return value }
    private func nullableID(_ args: [String: Any], _ key: String, required: Bool = true) throws -> UUID? {
        if args[key] is NSNull || (!required && args[key] == nil) { return nil }; return try id(args, key)
    }
    private func organizationRevision(_ args: [String: Any]) throws -> UUID? { try nullableID(args, "expectedOrganizationRevision") }
    private func revision(_ args: [String: Any]) throws -> UInt64 {
        let value = try string(args, "expectedRevision")
        guard let revision = UInt64(value), String(revision) == value else { throw Failure.invalid }; return revision
    }
}
