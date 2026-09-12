import Foundation

/// A deliberately small, exportable support package. It contains only the
/// readiness projection and coarse runtime facts; profile data, URLs, proxy
/// values, cookies, paths and identifiers never enter the payload.
struct PrivacySafeDiagnosticPackage: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let exportedAt: Date
    let readiness: String
    let checks: [String]

    init(snapshot: WorkspaceReadinessSnapshot, exportedAt: Date = Date()) {
        schemaVersion = Self.schemaVersion
        self.exportedAt = exportedAt
        // Keep the export intentionally coarser than the on-screen diagnostic
        // text: it must never contain route/profile labels or local paths.
        readiness = "NeAntik readiness: \(snapshot.level.title)"
        checks = snapshot.items.map { "check:\($0.level.rawValue)" }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder.neantikStable
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
