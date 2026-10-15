import Foundation
import Testing
@testable import NeAntik

// Fixed compatibility fixtures, independent of the catalog implementation.
// Four current Air cohorts are a subset of the eleven immutable legacy tuples.
private let legacyTuples = [
    "macbook-air-m1", "macbook-pro-m1-pro", "macbook-air-m2",
    "macbook-pro-m2-max", "macbook-pro-m2-pro", "macbook-air-m3",
    "macbook-pro-m3-max", "macbook-pro-m3-pro", "macbook-air-m4",
    "macbook-pro-m4-max", "macbook-pro-m4-pro"
]
private let identityRows: [(UInt32, Int, String)] = legacyTuples.enumerated().map {
    (UInt32(11 + $0.offset), 1, $0.element)
} + [(33, 2, "macbook-air-m1"), (24, 2, "macbook-air-m2"),
     (27, 2, "macbook-air-m3"), (30, 2, "macbook-air-m4")]

@MainActor
@Suite(.serialized)
struct PersistedIdentityMatrixTests {
    @Test(arguments: identityRows)
    func oldMetadataSurvivesReloadEditAndCollision(row: (UInt32, Int, String)) throws {
        let (seed, issuance, tuple) = row
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neantik-identity-matrix-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(rootDirectory: root)
        try paths.prepareBaseDirectories()
        let original = BrowserProfile(name: "Own identity fixture", identity: BrowserIdentity(seed: seed))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var metadata = try #require(JSONSerialization.jsonObject(with: encoder.encode([original])) as? [[String: Any]])
        // Legacy data deliberately omits the later catalog/issuance/tuple fields.
        var identity: [String: Any] = ["seed": seed]
        if issuance == 2 {
            identity["catalogVersion"] = 1
            identity["issuanceVersion"] = issuance
            identity["deviceTupleID"] = tuple
        }
        metadata[0]["identity"] = identity
        metadata[0].removeValue(forKey: "fontPolicy")
        try paths.writePrivateFile(JSONSerialization.data(withJSONObject: metadata), to: paths.profilesFile)

        let loaded = ProfileStore(paths: paths)
        #expect(loaded.lastError == nil)
        let migrated = try #require(loaded.profile(withID: original.id))
        #expect(migrated.fontPolicy == .native)
        #expect(migrated.identity.seed == seed)
        #expect(migrated.identity.catalogVersion == 1)
        #expect(migrated.identity.issuanceVersion == issuance)
        #expect(migrated.identity.deviceTupleID == tuple)
        _ = try loaded.upsert(migrated)

        let editing = ProfileStore(paths: paths)
        #expect(editing.lastError == nil)
        var edited = try #require(editing.profile(withID: original.id))
        #expect(edited.identity == migrated.identity)
        edited.name = "Renamed own fixture"
        edited.identity = edited.identity.replacingProxyContext(timezoneIdentifier: "Europe/Berlin",
            localeIdentifier: "de-DE", evidence: .ipAPI(observedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let saved = try editing.upsert(edited)
        let collision = try editing.upsert(BrowserProfile(name: "Own duplicate seed", identity: saved.identity))
        #expect(collision.identity.seed == seed + 11)
        #expect(collision.identity.deviceTupleID == tuple)
        #expect(collision.identity.issuanceVersion == issuance)
        #expect(saved.fontPolicy == .native && collision.fontPolicy == .native)

        let reloaded = ProfileStore(paths: paths)
        #expect(reloaded.lastError == nil)
        let retained = try #require(reloaded.profile(withID: original.id))
        #expect(retained.fontPolicy == .native)
        #expect(retained.name == edited.name)
        #expect(retained.identity == saved.identity)
        #expect(retained.identity.seed == seed)
        #expect(retained.identity.catalogVersion == 1)
        #expect(retained.identity.deviceTupleID == tuple)
        #expect(retained.identity.issuanceVersion == issuance)
        #expect(reloaded.profile(withID: collision.id)?.identity == collision.identity)
        #expect(reloaded.profiles.count == 2)
    }

    @Test(arguments: ["tuple", "catalog", "issuance", "outsideCurrentCohorts"])
    func incompatibleIdentityCannotBecomeAValidProfile(change: String) throws {
        var identity: [String: Any] = ["seed": 33, "catalogVersion": 1, "issuanceVersion": 2,
                                      "deviceTupleID": "macbook-air-m1"]
        switch change {
        case "tuple": identity["deviceTupleID"] = "macbook-air-m2"
        case "catalog": identity["catalogVersion"] = 2
        case "issuance": identity["issuanceVersion"] = 3
        default:
            identity["seed"] = 12
            identity["deviceTupleID"] = "macbook-pro-m1-pro"
        }
        let data = try JSONSerialization.data(withJSONObject: identity)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BrowserIdentity.self, from: data) }
    }
}
