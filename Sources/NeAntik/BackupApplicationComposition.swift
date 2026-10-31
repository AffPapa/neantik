import Foundation

/// Only this separately signed QA identity may select a real test DP group.
/// Invalid metadata refuses startup instead of falling into a development library.
struct BackupGUIQualificationContext: Equatable, Sendable {
    static let bundleIdentifier = "app.neantik.desktop.backup-qa"
    static let accessGroup = "H6VGU2M6JD.app.neantik.desktop.backup-qa"
    static let runIDKey = "NeAntikBackupQualificationRunID"
    static let rootKey = "NeAntikBackupQualificationRoot"
    let runID: UUID
    let root: URL
    var service: String { Self.bundleIdentifier + ".browser-data-backup-scope." + runID.uuidString.lowercased() }
    private init(runID: UUID, root: URL) { self.runID = runID; self.root = root }

    static func resolve(bundleIdentifier: String?, runID: String?, root: String?) throws -> Self? {
        guard bundleIdentifier == Self.bundleIdentifier else {
            guard runID == nil, root == nil else { throw BackupCompatibilityScopeError.unavailable }
            return nil
        }
        #if DEBUG
        guard let runID, let uuid = UUID(uuidString: runID),
              let root, root == BackupScopeQualification.dataRoot(uuid).path else {
            throw BackupCompatibilityScopeError.unavailable
        }
        return Self(runID: uuid, root: URL(fileURLWithPath: root, isDirectory: true))
        #else
        throw BackupCompatibilityScopeError.unavailable
        #endif
    }
}

/// One selection at the application root is shared by export and recovery.
struct BackupApplicationComposition: Sendable {
    static let productionCapabilityKey = "NeAntikBrowserDataBackupEnabled"
    static let productionAccessGroup = "H6VGU2M6JD.app.neantik.desktop"
    let scope: BackupCompatibilityScopeStore
    let allowsNewOperations: Bool
    static var unavailable: Self {
        .init(scope: .init(backend: UnavailableBackupCompatibilityScopeBackend()), allowsNewOperations: false)
    }

    static func resolve(
        environment: NeAntikApplicationEnvironment, paths: AppPaths,
        validatedReleaseAudit: Bool, qualification: BackupGUIQualificationContext? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fixtureRoot: String? = Bundle.main.object(forInfoDictionaryKey: "NeAntikDevelopmentFixtureRoot") as? String,
        developmentEnabled: Bool = Bundle.main.object(forInfoDictionaryKey: "NeAntikBrowserDataBackupDevelopmentEnabled") as? Bool == true,
        productionEnabled: Bool = Bundle.main.object(forInfoDictionaryKey: productionCapabilityKey) as? Bool == true,
        securityBackend: @Sendable (String, String?) -> any BackupCompatibilityScopeBackend = {
            SecurityBackupCompatibilityScopeBackend(service: $0, accessGroup: $1)
        }
    ) throws -> Self {
        // The authenticated audit context wins before any QA or Keychain choice.
        if validatedReleaseAudit { return .unavailable }
        // A development switch or a foreign identity cannot enable production
        // access. Signing gates authenticate the capability/profile; Security
        // independently enforces this exact group without a file fallback.
        if productionEnabled {
            guard bundleIdentifier == NeAntikApplicationEnvironment.productionBundleIdentifier,
                  environment.bundleIdentifier == bundleIdentifier, qualification == nil else {
                throw BackupCompatibilityScopeError.unavailable
            }
            return .init(scope: .init(backend: securityBackend(
                environment.bundleIdentifier + ".browser-data-backup-scope", productionAccessGroup)),
                allowsNewOperations: true)
        }
        #if DEBUG
        if let qualification {
            guard bundleIdentifier == BackupGUIQualificationContext.bundleIdentifier,
                  environment.isDevelopment, paths.rootDirectory.path == qualification.root.path else {
                throw BackupCompatibilityScopeError.unavailable
            }
            return .init(scope: .init(backend: securityBackend(qualification.service, BackupGUIQualificationContext.accessGroup)),
                         allowsNewOperations: true)
        }
        #endif
        guard bundleIdentifier != BackupGUIQualificationContext.bundleIdentifier, qualification == nil else {
            throw BackupCompatibilityScopeError.unavailable
        }
        #if DEBUG
        if KeychainStore.usesDisposableDevelopmentBackend(environment: environment, paths: paths, fixtureRoot: fixtureRoot) {
            return .init(scope: .init(backend: DevelopmentFixtureBackupScope(paths: paths)), allowsNewOperations: developmentEnabled)
        }
        #endif
        // Legacy releases retain recovery selection without enabling creation.
        return .init(scope: .init(backend: securityBackend(environment.bundleIdentifier + ".browser-data-backup-scope", nil)),
                     allowsNewOperations: false)
    }
}
