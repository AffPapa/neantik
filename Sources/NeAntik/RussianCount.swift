enum RussianCount {
    static func word(_ count: Int, one: String, few: String, many: String) -> String {
        if (11...14).contains(count % 100) { return many }
        switch count % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    static func title(_ count: Int, one: String, few: String, many: String) -> String {
        "\(count) \(word(count, one: one, few: few, many: many))"
    }
}
