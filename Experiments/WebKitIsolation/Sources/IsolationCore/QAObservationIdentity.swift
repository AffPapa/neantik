import Foundation

/// UUID spelling is not authority: compare parsed run identities, while still
/// refusing a missing, malformed or different run from a late provider reply.
public enum QAObservationIdentity {
    public static func matches(actual: String?, expected: String?) -> Bool {
        guard let actual, let expected,
              let observed = UUID(uuidString: actual),
              let required = UUID(uuidString: expected) else { return false }
        return observed == required
    }
}
