import Foundation

/// Byte-level evidence framing only; callers still validate exact keys and schema.
enum CanonicalEvidenceJSON {
    static func object(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              canonical == data
        else { return nil }
        return dictionary
    }
}
