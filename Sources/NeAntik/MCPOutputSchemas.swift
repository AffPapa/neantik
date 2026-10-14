import Foundation

/// Public allowlisted DTOs, shared by discovery and positive contract tests.
enum MCPOutputSchemas {
    static func schema(for name: String) -> [String: Any] {
        let text: [String: Any] = ["type": "string"]
        let uuid: [String: Any] = ["type": "string", "format": "uuid"]
        let nullable: [String: Any] = ["type": ["string", "null"]]
        let revision: [String: Any] = ["type": "string", "pattern": "^(0|[1-9][0-9]*)$"]
        let boolean: [String: Any] = ["type": "boolean"]
        let count: [String: Any] = ["type": "integer", "minimum": 0]
        let state: [String: Any] = ["type": "string", "enum": ["managed", "stopped", "checking", "externalManualOnly", "externalUnverified", "recoveryRequired"]]
        let folder = object(["id": uuid, "name": text])
        let folders: [String: Any] = ["type": "array", "items": folder, "maxItems": 100]
        if name == "template_list" {
            return object(["templates": ["type": "array", "maxItems": ManagerLibraryDocument.maximumItems,
                "items": object(["id": uuid, "name": text, "startURL": text, "startupMode": ["type": "string", "enum": BrowserStartupMode.allCases.map(\.rawValue)], "engine": ["type": "string", "enum": BrowserEngine.allCases.map(\.rawValue)], "webKitMediaPolicy": ["type": ["string", "null"], "enum": WebKitMediaPolicy.allCases.map { $0.rawValue as Any } + [NSNull()]],
                    "tags": ["type": "array", "maxItems": 8, "items": text], "folderID": nullable])],
                "count": count, "organizationRevision": nullable])
        }
        if name == "folder_list" { return object(["organizationRevision": nullable, "folders": folders, "count": count, "totalCount": count, "nextCursor": nullable]) }
        if name.hasPrefix("folder_") { return object(["organizationRevision": nullable, "folders": ["type": "array", "items": folder, "maxItems": 1], "affectedFolderID": uuid]) }
        if name == "workspace_query_profiles" {
            let profile = object(["id": uuid, "revision": revision, "name": text, "tags": ["type": "array", "items": text], "isPinned": boolean, "isArchived": boolean, "folderID": nullable, "processState": ["type": "string", "const": "unverified"]])
            return object(["profiles": ["type": "array", "items": profile, "maxItems": 100], "count": count, "totalCount": count, "organizationRevision": nullable, "nextCursor": nullable])
        }
        if name == "profile_status" {
            let transportCount: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 9_007_199_254_740_991]
            let end: [String: Any] = ["type": ["string", "null"], "enum": BrowserRelayActivity.End.allCases.map { $0.rawValue as Any } + [NSNull()]]
            let transport = object([
                "state": ["type": "string", "const": "observed"], "sequence": transportCount,
                "admittedConnections": transportCount, "upstreamTunnels": transportCount, "successRepliesSent": transportCount,
                "completedConnections": transportCount, "failedConnections": transportCount, "cancelledConnections": transportCount,
                "activeConnections": ["type": "integer", "minimum": 0, "maximum": 64], "listenerStopped": boolean,
                "countersSaturated": boolean, "lastEnd": end, "lastFailure": end,
                "lastFailureSequence": ["type": ["integer", "null"], "minimum": 0, "maximum": 9_007_199_254_740_991],
                "lastEventAgeMilliseconds": ["type": ["integer", "null"], "minimum": 0, "maximum": 9_007_199_254_740_991]
            ])
            let observation = object([
                "state": ["type": "string", "enum": ["observed", "unavailable"]],
                "ownership": ["type": "string", "enum": ["thisSession", "notOwned", "unverified"]],
                "readyForGracefulQuit": ["type": ["boolean", "null"]],
                "runtimeVersion": nullable,
                "configuredRoute": ["type": "string", "enum": ["direct", "httpProxy", "httpsProxy", "socks5Proxy", "unknown"]],
                "chromiumRoute": ["type": "string", "const": "notObserved"],
                "pageObservation": ["type": "string", "const": "notSupported"],
                "extensionsObservation": ["type": "string", "const": "notObserved"],
                "relayTransport": ["oneOf": [transport, object(["state": ["type": "string", "const": "notObserved"]])]]
            ])
            return object(["profileID": uuid, "processState": state, "revision": revision,
                           "observation": observation], optional: ["revision", "observation"])
        }
        if name == "profile_stop" { return object(["profileID": uuid, "processState": state, "stopRequested": boolean]) }
        if name == "profile_start" { return object(["profileID": uuid, "processState": state, "revision": revision]) }
        if name == "profile_check_proxy" { return object(["profileID": uuid, "outcome": text, "chromiumRoute": ["type": "string", "const": "unverified"]]) }
        return object(["id": uuid, "revision": revision, "name": text, "startURL": text, "startupMode": ["type": "string", "enum": BrowserStartupMode.allCases.map(\.rawValue)], "engine": ["type": "string", "enum": BrowserEngine.allCases.map(\.rawValue)], "webKitMediaPolicy": ["type": ["string", "null"], "enum": WebKitMediaPolicy.allCases.map { $0.rawValue as Any } + [NSNull()]], "tags": ["type": "array", "items": text], "isPinned": boolean, "isArchived": boolean,
                       "colorHex": text, "symbolName": text, "folderID": nullable, "organizationRevision": nullable,
                       "proxyKind": ["type": ["string", "null"], "enum": ["http", "https", "socks5", NSNull()]], "warning": text], optional: ["warning"])
    }
    private static func object(_ properties: [String: Any], optional: Set<String> = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.filter { !optional.contains($0) }.sorted(), "additionalProperties": false]
    }
}
