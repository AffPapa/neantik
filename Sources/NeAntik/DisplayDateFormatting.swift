import Foundation

enum DisplayDateFormatting {
    static let russianDateTime = Date.FormatStyle(
        date: .abbreviated,
        time: .shortened,
        locale: Locale(identifier: "ru_RU")
    )
}

extension Date {
    var neAntikDisplayDateTime: String {
        formatted(DisplayDateFormatting.russianDateTime)
    }
}
