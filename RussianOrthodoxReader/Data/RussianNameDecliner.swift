import Foundation

/// Склонённые формы имени.
struct DeclinedName: Hashable {
    let nominative: String
    let genitive: String
    let accusative: String
    let dative: String
}

/// Склонение русских личных имён по правилам — запасной путь для имён,
/// которых нет в church_names.sqlite. Формы, полученные правилами,
/// интерфейс помечает как «проверьте» и даёт отредактировать.
enum RussianNameDecliner {

    private static let vowels = Set("аеёиоуыэюя")
    private static let hushingOrVelar = Set("гкхжчшщ")

    /// Женские имена на -ь (мужские на -ь склоняются иначе: Игорь → Игоря).
    private static let feminineSoftSign: Set<String> = [
        "любовь", "нинель", "адель", "асель", "рахиль", "эсфирь", "юдифь"
    ]

    /// Эвристика определения пола по окончанию имени.
    static func guessGender(_ name: String) -> PersonGender {
        let lower = name.lowercased()
        if feminineSoftSign.contains(lower) { return .female }
        if lower.hasSuffix("а") || lower.hasSuffix("я") { return .female }
        return .male
    }

    /// Склоняет имя по общим правилам. Возвращает nil, если имя пустое.
    static func decline(_ name: String, gender: PersonGender) -> DeclinedName? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let lower = trimmed.lowercased()

        func stem(_ drop: Int) -> String { String(trimmed.dropLast(drop)) }

        switch gender {
        case .male:
            if lower.hasSuffix("ия") {                    // Илия, Захария
                return DeclinedName(nominative: trimmed, genitive: stem(1) + "и",
                                    accusative: stem(1) + "ю", dative: stem(1) + "и")
            }
            if lower.hasSuffix("й") {                     // Николай, Георгий, Матфей
                return DeclinedName(nominative: trimmed, genitive: stem(1) + "я",
                                    accusative: stem(1) + "я", dative: stem(1) + "ю")
            }
            if lower.hasSuffix("а") {                     // Савва, Никита, Лука
                let base = stem(1)
                let gen = base + (hushingOrVelar.contains(base.last ?? " ") ? "и" : "ы")
                return DeclinedName(nominative: trimmed, genitive: gen,
                                    accusative: base + "у", dative: base + "е")
            }
            if lower.hasSuffix("я") {                     // Илья (светская форма)
                return DeclinedName(nominative: trimmed, genitive: stem(1) + "и",
                                    accusative: stem(1) + "ю", dative: stem(1) + "е")
            }
            if lower.hasSuffix("ь") {                     // Игорь
                return DeclinedName(nominative: trimmed, genitive: stem(1) + "я",
                                    accusative: stem(1) + "я", dative: stem(1) + "ю")
            }
            if let last = lower.last, !vowels.contains(last) {  // Иоанн, Стефан
                return DeclinedName(nominative: trimmed, genitive: trimmed + "а",
                                    accusative: trimmed + "а", dative: trimmed + "у")
            }
            return nil                                     // -о, -е, -у: несклоняемое

        case .female:
            if lower.hasSuffix("ия") {                    // Фотиния, Мария
                return DeclinedName(nominative: trimmed, genitive: stem(1) + "и",
                                    accusative: stem(1) + "ю", dative: stem(1) + "и")
            }
            if lower.hasSuffix("а") {                     // Анна, Ольга
                let base = stem(1)
                let gen = base + (hushingOrVelar.contains(base.last ?? " ") ? "и" : "ы")
                return DeclinedName(nominative: trimmed, genitive: gen,
                                    accusative: base + "у", dative: base + "е")
            }
            if lower.hasSuffix("я") {                     // Зоя
                return DeclinedName(nominative: trimmed, genitive: stem(1) + "и",
                                    accusative: stem(1) + "ю", dative: stem(1) + "е")
            }
            if lower.hasSuffix("ь") {                     // Любовь
                return DeclinedName(nominative: trimmed, genitive: stem(1) + "и",
                                    accusative: trimmed, dative: stem(1) + "и")
            }
            return nil                                     // несклоняемое (Кэтрин и т.п.)
        }
    }
}
