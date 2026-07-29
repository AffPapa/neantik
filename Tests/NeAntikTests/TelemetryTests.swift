import Foundation
import Testing
@testable import NeAntik

struct TelemetryTests {
    @Test
    func payloadContainsOnlyDocumentedAggregateFields() throws {
        let payload = TelemetryPayload(
            eventID: "2b79ac84-6d66-4868-9764-cda62b1f1ea9",
            edition: .direct,
            version: "0.3.8",
            build: "11",
            osMajor: 26,
            profileCount: 4,
            proxyProfileCount: 2,
            event: .profileCreated
        )
        let object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(payload)
            ) as? [String: Any]
        )

        #expect(
            Set(object.keys) == [
                "schemaVersion",
                "eventID",
                "edition",
                "version",
                "build",
                "osMajor",
                "architecture",
                "profileCount",
                "proxyProfileCount",
                "event"
            ]
        )
        let encoded = String(
            data: try JSONSerialization.data(withJSONObject: object),
            encoding: .utf8
        ) ?? ""
        for forbidden in [
            "profileName",
            "profileID",
            "installationHash",
            "proxyHost",
            "proxyPort",
            "proxyPassword",
            "fingerprintSeed",
            "visitedURL"
        ] {
            #expect(!encoded.contains(forbidden))
        }
    }

    @Test
    func snapshotClampsCountsWithoutInventingProfiles() {
        #expect(
            TelemetrySnapshot(
                profileCount: -1,
                proxyProfileCount: 8
            ) == TelemetrySnapshot(
                profileCount: 0,
                proxyProfileCount: 0
            )
        )
        #expect(
            TelemetrySnapshot(
                profileCount: 3,
                proxyProfileCount: 9
            ).proxyProfileCount == 3
        )
    }
}
