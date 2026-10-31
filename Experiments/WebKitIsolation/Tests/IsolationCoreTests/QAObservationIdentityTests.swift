import Foundation
import Testing
@testable import IsolationCore

@Suite struct QAObservationIdentityTests {
    private let prepared = "d8736e20-4ab0-46a1-9d89-00bce02690fb"

    @Test func actualProviderSerializationMatchesPreparedRun() throws {
        let run = try #require(UUID(uuidString: prepared))
        let data = try JSONSerialization.data(withJSONObject: ["runID": run.uuidString])
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        // Negative control: the former exact-string comparison rejects this
        // real Foundation UUID serialization from the correct provider run.
        #expect(payload["runID"] != prepared)
        #expect(QAObservationIdentity.matches(actual: payload["runID"], expected: prepared))
    }

    @Test func differentRunStillRefuses() {
        #expect(!QAObservationIdentity.matches(actual: "00000000-0000-4000-8000-000000000001", expected: prepared))
    }

    @Test func missingRunRefuses() {
        #expect(!QAObservationIdentity.matches(actual: nil, expected: prepared))
        #expect(!QAObservationIdentity.matches(actual: prepared, expected: nil))
    }

    @Test func malformedRunRefuses() {
        for text in ["", "invalid", prepared + "extra", " " + prepared] {
            #expect(!QAObservationIdentity.matches(actual: text, expected: prepared))
            #expect(!QAObservationIdentity.matches(actual: prepared, expected: text))
        }
    }
}
