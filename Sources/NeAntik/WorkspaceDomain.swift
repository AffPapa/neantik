import Foundation

/// One immutable projection over the canonical ProfileStore, process manager,
/// proxy-health history and runtime inspection. It does not own or persist a
/// second copy of product state.
struct WorkspaceSnapshot: Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let folders: [WorkspaceFolderState]
    let profiles: [WorkspaceProfileState]
    let environmentsByProfileID: [UUID: ProfileEnvironmentSnapshot]

    func environment(for profileID: UUID) -> ProfileEnvironmentSnapshot? {
        environmentsByProfileID[profileID]
    }

    func publicDTO() -> WorkspacePublicSnapshotDTO {
        WorkspacePublicSnapshotDTO(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            folders: folders.map {
                WorkspacePublicFolderDTO(
                    id: $0.id,
                    name: $0.name,
                    profileCount: $0.profileCount
                )
            },
            profiles: profiles.map {
                WorkspacePublicProfileDTO(
                    id: $0.id,
                    name: $0.name,
                    tags: $0.tags,
                    folderID: $0.folderID,
                    isPinned: $0.isPinned,
                    isArchived: $0.isArchived,
                    isRunning: $0.isRunning,
                    proxyKind: $0.proxyKind,
                    latestProxyOutcome: $0.latestProxyOutcome,
                    proxyCheckedAt: $0.proxyCheckedAt,
                    proxyResponseTimeMilliseconds:
                        $0.proxyResponseTimeMilliseconds
                )
            }
        )
    }
}

struct WorkspaceFolderState: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let profileCount: Int
}

struct WorkspaceProfileState: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let tags: [String]
    let note: String
    let folderID: UUID?
    let isPinned: Bool
    let isArchived: Bool
    let isRunning: Bool
    let proxyKind: ProxyKind?
    let latestProxyOutcome: ProxyHealthOutcome?
    let proxyCheckedAt: Date?
    let proxyResponseTimeMilliseconds: Int?
}

/// Explicit allowlist for a future opt-in local API, MCP adapter and SDK.
/// Browser paths, proxy endpoints, usernames, passwords, exact IP addresses,
/// fingerprint seeds/codes/hashes and raw WebRTC evidence have no fields here.
struct WorkspacePublicSnapshotDTO: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let folders: [WorkspacePublicFolderDTO]
    let profiles: [WorkspacePublicProfileDTO]
}

struct WorkspacePublicFolderDTO: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let profileCount: Int
}

struct WorkspacePublicProfileDTO: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let tags: [String]
    let folderID: UUID?
    let isPinned: Bool
    let isArchived: Bool
    let isRunning: Bool
    let proxyKind: ProxyKind?
    let latestProxyOutcome: ProxyHealthOutcome?
    let proxyCheckedAt: Date?
    let proxyResponseTimeMilliseconds: Int?
}

enum WorkspaceDomain {
    static func environmentSnapshot(
        profile: BrowserProfile,
        runtime: BrowserRuntime?,
        proxyHealth: ProxyHealthState?,
        fingerprintObservation:
            ValidatedProfileFingerprintObservation? = nil,
        now: Date = Date()
    ) -> ProfileEnvironmentSnapshot {
        ProfileEnvironmentInspector.snapshot(
            profile: profile,
            runtime: runtime,
            proxyHealth: proxyHealth,
            fingerprintObservation: fingerprintObservation,
            now: now
        )
    }

    static func snapshot(
        profiles: [BrowserProfile],
        organization: ProfileOrganizationState,
        runningProfileIDs: Set<UUID>,
        proxyHealthStates: [UUID: ProxyHealthState],
        runtime: BrowserRuntime?,
        fingerprintObservations:
            [UUID: ValidatedProfileFingerprintObservation] = [:],
        now: Date = Date()
    ) -> WorkspaceSnapshot {
        let profileIDs = Set(profiles.map(\.id))
        let folderStates = organization.folders.map { folder in
            WorkspaceFolderState(
                id: folder.id,
                name: folder.name,
                profileCount: organization.profileIDs(
                    inFolderID: folder.id
                ).filter(profileIDs.contains).count
            )
        }
        let profileStates = profiles.map { profile in
            let health = proxyHealthStates[profile.id]
            return WorkspaceProfileState(
                id: profile.id,
                name: profile.name,
                tags: profile.tags,
                note: profile.note,
                folderID: organization.folderID(
                    forProfileID: profile.id
                ),
                isPinned: profile.isPinned,
                isArchived: profile.isArchived,
                isRunning: runningProfileIDs.contains(profile.id),
                proxyKind: profile.proxy?.kind,
                latestProxyOutcome: health?.latestAttempt.outcome,
                proxyCheckedAt: health?.latestAttempt.checkedAt,
                proxyResponseTimeMilliseconds:
                    health?.latestAttempt.responseTimeMilliseconds
            )
        }
        let environments = Dictionary(
            uniqueKeysWithValues: profiles.map { profile in
                (
                    profile.id,
                    environmentSnapshot(
                        profile: profile,
                        runtime: runtime,
                        proxyHealth: proxyHealthStates[profile.id],
                        fingerprintObservation:
                            fingerprintObservations[profile.id],
                        now: now
                    )
                )
            }
        )
        return WorkspaceSnapshot(
            schemaVersion: WorkspaceSnapshot.currentSchemaVersion,
            generatedAt: now,
            folders: folderStates,
            profiles: profileStates,
            environmentsByProfileID: environments
        )
    }
}
