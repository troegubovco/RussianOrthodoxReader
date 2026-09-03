import Foundation

// MARK: - Утилиты текста молитвы

enum StressMarks {
    /// Удаляет знаки ударения (U+0301) из текста.
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{0301}", with: "")
    }
}

/// Язык отображения текста молитвы.
enum PrayerLanguage: String, CaseIterable, Identifiable {
    case churchSlavonic = "cs"
    case russian = "ru"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .churchSlavonic: return "Церковнославянский"
        case .russian: return "Русский"
        }
    }

    var shortTitle: String {
        switch self {
        case .churchSlavonic: return "ЦС"
        case .russian: return "Русский"
        }
    }
}
