import Foundation

/// Подстановка имён в шаблонные молитвы.
///
/// Токены в тексте молитвы:
///   [[NAMES]]                 — список имён (уже склонённых в нужный падеж)
///   [[V|m:…|f:…|pl:…]]        — вариант фразы: один мужчина → m,
///                               одна женщина → f, двое и более → pl,
///                               ни одного имени → m (и «(имярек)» вместо имён)
///
/// Вставленные имена оборачиваются маркерами ⟦…⟧ — интерфейс подсвечивает их
/// акцентным цветом (см. PrayerTextView).
enum PrayerTemplateRenderer {

    struct NameToInsert: Hashable {
        let declined: String     // «Георгия» — уже в падеже молитвы
        let gender: PersonGender
    }

    static let nameMarkerOpen = "⟦"
    static let nameMarkerClose = "⟧"

    private static let variantPattern = /\[\[V\|m:(?<m>[^|\]]+)\|f:(?<f>[^|\]]+)\|pl:(?<pl>[^\]]+)\]\]/

    static func render(_ template: String, names: [NameToInsert]) -> String {
        let variant: Substring
        switch (names.count, names.first?.gender) {
        case (0, _), (1, .male): variant = "m"
        case (1, .female):       variant = "f"
        default:                 variant = "pl"
        }

        var result = template.replacing(variantPattern) { match in
            switch variant {
            case "f":  return String(match.output.f)
            case "pl": return String(match.output.pl)
            default:   return String(match.output.m)
            }
        }

        let joined: String
        if names.isEmpty {
            joined = "(имярек)"
        } else {
            let marked = names.map { nameMarkerOpen + $0.declined + nameMarkerClose }
            joined = Self.joinNames(marked)
        }
        result = result.replacingOccurrences(of: "[[NAMES]]", with: joined)
        return result
    }

    /// «А», «А и Б», «А, Б и В»
    static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default:
            return names.dropLast().joined(separator: ", ") + " и " + names[names.count - 1]
        }
    }
}
