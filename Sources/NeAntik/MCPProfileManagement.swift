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

    init(root: URL, allowsManagement: Bool, keychain: KeychainStore? = nil,
         processes: BrowserProcessManager? = nil) {
        let paths = AppPaths(rootDirectory: root)
        let environment = NeAntikApplicationEnvironment.resolve(bundleIdentifier: Bundle.main.bundleIdentifier)
        self.keychain = keychain ?? KeychainStore(service: environment.keychainService, legacyService: environment.legacyKeychainService)
        store = ProfileStore(paths: paths, readOnlyMetadata: !allowsManagement)
        self.processes = processes ?? BrowserProcessManager(paths: paths)
        health = ProxyHealthCoordinator(fileURL: paths.proxyHealthFile)
        self.allowsManagement = allowsManagement
    }

    enum Failure: Error { case invalid, conflict, unavailable, running, proxyFailed, manualClose, denied, stopRefused, cursor, responseLimit }

    nonisolated static let readTools = ["profile_get", "folder_list", "profile_status", "workspace_query_profiles"]
    nonisolated static let writeTools = ["profile_create", "profile_update", "profile_set_proxy", "profile_move", "profile_duplicate", "folder_create", "folder_rename", "folder_remove", "profile_check_proxy", "profile_start", "profile_stop"]
    nonisolated static var allTools: [String] { ["workspace_list_profiles", "workspace_list_profiles_page"] + readTools + writeTools }

    nonisolated static func definitions(allowsManagement: Bool) -> [[String: Any]] {
        let text: [String: Any] = ["type": "string"]
        let uuid: [String: Any] = ["type": "string", "format": "uuid"]
        let revision: [String: Any] = ["type": "string", "pattern": "^(0|[1-9][0-9]*)$"]
        let optionalUUID: [String: Any] = ["type": ["string", "null"]]
        let changes: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
            "name": text, "startURL": text, "tags": ["type": "array", "maxItems": 8, "items": text],
            "note": text, "isPinned": ["type": "boolean"], "isArchived": ["type": "boolean"], "colorHex": text, "symbolName": text]]
        let proxyFields: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["kind", "host", "port"], "properties": [
            "kind": ["type": "string", "enum": ["http", "https", "socks5"]], "host": text,
            "port": ["type": "integer", "minimum": 1, "maximum": 65535], "username": text, "password": text]]
        let specs: [(String, String, [String: Any], [String])] = [
            ("profile_get", "Read profile revision, start page and organization; proxy endpoint and credentials excluded; note excluded.", ["profileID": uuid], ["profileID"]),
            ("folder_list", "Read up to100 project folders and organizationRevision. Pass nextCursor unchanged; restart on organization change.", ["limit": ["type": "integer", "minimum": 1, "maximum": 100], "cursor": text], []),
            ("workspace_query_profiles", "Find profiles by name, tags and project without reading private notes. Tags use AND; omitted archived means active only. folderID:null means unfiled, omission means any. Cursor is tied to filters and snapshot. Process state remains unverified.", MCPWorkspaceQuery.properties, []),
            ("profile_status", "Reconcile profile ownership. External sessions require manual close.", ["profileID": uuid], ["profileID"]),
            ("profile_create", "Create a persistent profile without starting it. No automatic retry: a repeat creates another profile.", ["name": text, "changes": changes, "folderID": optionalUUID, "expectedOrganizationRevision": optionalUUID], ["name"]),
            ("profile_update", "Patch an existing stopped profile; omitted fields stay unchanged. Read its revision first.", ["profileID": uuid, "expectedRevision": revision, "changes": changes], ["profileID", "expectedRevision", "changes"]),
            ("profile_set_proxy", "Configure/disable a stopped profile proxy. Use proxy:null, proxy fields, or proxyLine with kind/order. Password is write-only; input may enter AI history. SOCKS5 authentication unsupported. Configuration is not a route test.", ["profileID": uuid, "expectedRevision": revision, "proxy": ["anyOf": [proxyFields, ["type": "null"]]], "proxyLine": text, "kind": ["type": "string", "enum": ["http", "https", "socks5"]], "order": ["type": "string", "enum": ["automatic", "credentialsFirst", "endpointFirst"]]], ["profileID", "expectedRevision"]),
            ("profile_move", "Move stopped profile to folder/project or null (unfiled). Both revisions protect concurrent changes.", ["profileID": uuid, "expectedRevision": revision, "folderID": optionalUUID, "expectedOrganizationRevision": optionalUUID], ["profileID", "expectedRevision", "folderID", "expectedOrganizationRevision"]),
            ("profile_duplicate", "Copy configuration into a fresh identity; never copy cookies, notes or BrowserData. Copies proxy password via local Keychain without returning it.", ["profileID": uuid, "expectedRevision": revision, "name": text], ["profileID", "expectedRevision", "name"]),
            ("folder_create", "Create a project folder.", ["name": text, "expectedOrganizationRevision": optionalUUID], ["name", "expectedOrganizationRevision"]),
            ("folder_rename", "Rename a project folder using its current organization revision.", ["folderID": uuid, "name": text, "expectedOrganizationRevision": optionalUUID], ["folderID", "name", "expectedOrganizationRevision"]),
            ("folder_remove", "Remove only the folder; retain all profiles and website data, moving them to unfiled.", ["folderID": uuid, "expectedOrganizationRevision": optionalUUID], ["folderID", "expectedOrganizationRevision"]),
            ("profile_check_proxy", "Check proxy availability using existing bounded diagnostics; does not qualify Chromium route or change profile context.", ["profileID": uuid, "expectedRevision": revision], ["profileID", "expectedRevision"]),
            ("profile_start", "Start via the normal manager pipeline; fresh proxy preparation, no direct fallback. Browser remains open after MCP disconnect.", ["profileID": uuid, "expectedRevision": revision], ["profileID", "expectedRevision"]),
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
        do {
            try await store.refreshExternalMetadata()
        } catch {
            // These operations use independently validated profile IDs and process
            // ownership, never folder assignments. A broken sidecar must not
            // prevent gracefully closing a browser owned by this session.
            guard lifecycleOnly, store.hasTrustedMetadata, !store.hasTrustedOrganization else { throw error }
        }
        guard store.hasTrustedMetadata, lifecycleOnly || store.hasTrustedOrganization else { throw Failure.unavailable }
        try Task.checkCancellation()
        if name == "workspace_query_profiles" {
            let query = try MCPWorkspaceQuery(arguments: args)
            let profiles = store.profiles, organization = store.organization
            return try await Task.detached(priority: .userInitiated) {
                try query.page(profiles: profiles, organization: organization)
            }.value
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
            var profile = BrowserProfile(name: try string(args, "name"))
            try apply(args["changes"] as? [String: Any] ?? [:], to: &profile)
            try validate(profile)
            if let value = args["changes"], !(value is [String: Any]) { throw Failure.invalid }
            let folder = try nullableID(args, "folderID", required: false)
            let expected: UUID?? = args["expectedOrganizationRevision"] == nil ? nil : .some(try organizationRevision(args))
            if folder != nil && expected == nil { throw Failure.invalid }
            let saved = try store.upsert(profile, toFolderID: folder, expectedOrganizationRevision: expected)
            store.managerLibrary.record(.create, .succeeded)
            return dto(saved)
        }
        let profileID = try id(args, "profileID")
        guard var profile = store.profile(withID: profileID) else { throw Failure.unavailable }
        if name == "profile_get" { return dto(profile) }
        if name == "profile_status" {
            try await observe(profileID)
            return ["profileID": profileID.uuidString, "processState": status(profileID)]
        }
        if name == "profile_stop" {
            try await observe(profileID)
            let state = processes.processState(for: profileID)
            guard state == .managed || state == .stopped else { throw Failure.manualClose }
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
            return ["profileID": profileID.uuidString, "stopRequested": state == .managed, "processState": status(profileID)]
        }
        let expected = try revision(args)
        guard profile.revision == expected else { throw Failure.conflict }
        switch name {
        case "profile_start": return try await launch(profile)
        case "profile_check_proxy":
            try processes.withVerifiedStoppedProfileOperation(profileID: profileID) {}
            guard let proxy = profile.proxy else { throw Failure.invalid }
            let state = try await health.run(profile: profile, operationWithCurrentIdentity: { previous in
                try await ProfileProxyOperations(store: self.store, keychain: self.keychain, invalidateObservation: { _ in })
                    .commit(profileID: profileID, expectedProxy: proxy, expectedRevision: expected, previous: previous, commitsLaunchContext: false)
            })
            return ["profileID": profileID.uuidString, "outcome": state?.latestAttempt.outcome.userSummary ?? "No committed observation", "chromiumRoute": "unverified"]
        default: break
        }
        let result = try processes.withVerifiedStoppedProfileOperation(profileID: profileID) {
            switch name {
            case "profile_update":
                guard let changes = args["changes"] as? [String: Any], !changes.isEmpty else { throw Failure.invalid }
                let original = profile
                try apply(changes, to: &profile); try validate(profile)
                if original != profile { profile = try store.upsert(profile) }
            case "profile_move":
                profile = try store.upsert(profile, toFolderID: nullableID(args, "folderID"), expectedOrganizationRevision: .some(organizationRevision(args)))
            case "profile_set_proxy":
                let draft = try parseProxy(args)
                profile.proxy = draft?.configuration
                profile.identity = profile.identity.replacingProxyContext(timezoneIdentifier: nil, localeIdentifier: nil, evidence: nil)
                try validate(profile, password: draft?.password ?? "")
                profile = try store.upsert(profile, afterPersist: { saved in
                    try self.keychain.updateProxyPasswordForProfileEdit(draft?.password, profileID: saved.id)
                })
            case "profile_duplicate":
                let password = try keychain.proxyPassword(profileID: profileID)
                var copy = profile.duplicated(); copy.name = try string(args, "name"); try validate(copy, password: password ?? "")
                profile = try store.duplicateProfile(profile, name: copy.name, afterPersist: { saved in
                    if let password { try self.keychain.updateProxyPasswordForProfileEdit(password, profileID: saved.id) }
                })
            default: throw Failure.invalid
            }
            return dto(profile)
        }
        if name == "profile_set_proxy" {
            do { try await health.remove(profileID: profileID) }
            catch { var committed = result; committed["warning"] = "Proxy configuration saved; old diagnostic cleanup unavailable. Re-read current profile."; return committed }
        }
        return result
    }

    private func launch(_ initial: BrowserProfile) async throws -> [String: Any] {
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
        try processes.launch(profile: profile, runtime: runtime, preparationReceipt: receipt)
        guard store.markLaunched(profile.id) else { processes.stop(profileID: profile.id); throw Failure.unavailable }
        launched = true
        store.managerLibrary.record(.launch, .succeeded)
        return ["profileID": profile.id.uuidString, "processState": status(profile.id), "revision": String(store.profile(withID: profile.id)?.revision ?? profile.revision)]
    }

    private func apply(_ changes: [String: Any], to profile: inout BrowserProfile) throws {
        guard Set(changes.keys).isSubset(of: ["name", "startURL", "tags", "note", "isPinned", "isArchived", "colorHex", "symbolName"]) else { throw Failure.invalid }
        for (key, value) in changes {
            switch key {
            case "name": profile.name = try string(changes, key).trimmingCharacters(in: .whitespacesAndNewlines)
            case "startURL": guard let url = BrowserLaunchBuilder.validatedStartURL(try string(changes, key)) else { throw Failure.invalid }; profile.startURL = url.absoluteString
            case "note": guard let note = BrowserProfile.normalizedNote(try string(changes, key)) else { throw Failure.invalid }; profile.note = note
            case "tags": guard let tags = value as? [String], let normalized = BrowserProfile.normalizedTags(tags) else { throw Failure.invalid }; profile.tags = normalized
            case "isPinned", "isArchived": guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Failure.invalid }; if key == "isPinned" { profile.isPinned = number.boolValue } else { profile.isArchived = number.boolValue }
            case "colorHex": profile.colorHex = try string(changes, key)
            case "symbolName": profile.symbolName = try string(changes, key)
            default: throw Failure.invalid
            }
        }
    }

    private func validate(_ profile: BrowserProfile, password: String = "") throws {
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
        ["id": profile.id.uuidString, "revision": String(profile.revision), "name": profile.name, "startURL": profile.startURL,
         "tags": profile.tags, "isPinned": profile.isPinned, "isArchived": profile.isArchived,
         "colorHex": profile.colorHex, "symbolName": profile.symbolName, "folderID": store.folderID(forProfileID: profile.id)?.uuidString as Any? ?? NSNull(),
         "organizationRevision": store.organization.mutationRevision?.uuidString as Any? ?? NSNull(), "proxyKind": profile.proxy?.kind.rawValue as Any? ?? NSNull()]
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
        if processes.processState(for: profileID) == .managed { return }
        processes.reconcile(profiles: store.profiles)
        for _ in 0..<100 {
            try Task.checkCancellation()
            if processes.processState(for: profileID) != .checking { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func status(_ id: UUID) -> String {
        switch processes.processState(for: id) {
        case .managed: "managed"
        case .stopped: "stopped"
        case .externalManualOnly, .externalVerified: "externalManualOnly"
        case .checking: "checking"
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
