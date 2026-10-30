/// Explicit experimental transitions only. Version ordering alone must never
/// authorize replacement of an unknown, enabled or production extension.
public enum QAReplacementRecipe {
    public static func permits(from: String, to: String) -> Bool {
        (from == "3" && to == "5") || (from == "5" && to == "6") || (from == "6" && to == "7")
    }
}
