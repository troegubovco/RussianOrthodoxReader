import Foundation

// MARK: - Liturgical Domain

nonisolated enum ReadingKind: String, Codable, CaseIterable {
    case apostol
    case gospel
    case other
}

nonisolated struct ReadingReference: Identifiable, Hashable, Codable {
    let id: String
    let kind: ReadingKind
    /// Original API `source` field (e.g. "6th Hour", "Vespers", "Epistle", "Gospel").
    let sourceLabel: String
    let displayRef: String
    let bookId: String
    let chapter: Int
    let verseStart: Int
    let verseEnd: Int
    let ordinal: Int

    init(kind: ReadingKind,
         sourceLabel: String = "",
         displayRef: String,
         bookId: String,
         chapter: Int,
         verseStart: Int,
         verseEnd: Int,
         ordinal: Int) {
        self.kind = kind
        self.sourceLabel = sourceLabel
        self.displayRef = displayRef
        self.bookId = bookId
        self.chapter = chapter
        self.verseStart = verseStart
        self.verseEnd = verseEnd
        self.ordinal = ordinal
        self.id = "\(kind.rawValue):\(sourceLabel):\(bookId):\(chapter):\(verseStart)-\(verseEnd):\(ordinal)"
    }
}

struct LiturgicalDay: Identifiable, Hashable {
    enum FastingLevel: String, Codable {
        case none = ""
        case regular = "Постный день"
        case strict = "Строгий пост"
        case fish = "Разрешается рыба"
        case oil = "Разрешается елей"
    }

    let id: Date
    let date: Date
    let apostolReading: String
    let gospelReading: String
    let saintOfDay: String
    let tone: Int?
    let isSunday: Bool
    let isFastDay: Bool
    let fastingLevel: FastingLevel
    let references: [ReadingReference]
    let isFromCache: Bool
    let dataAvailabilityMessage: String?

    var apostolReferences: [ReadingReference] {
        references
            .filter { $0.kind == .apostol }
            .sorted { $0.ordinal < $1.ordinal }
    }

    var gospelReferences: [ReadingReference] {
        references
            .filter { $0.kind == .gospel }
            .sorted { $0.ordinal < $1.ordinal }
    }

    var extraReferences: [ReadingReference] {
        references
            .filter { $0.kind == .other }
            .sorted { $0.ordinal < $1.ordinal }
    }
}

// MARK: - Paschal Computation (Julian Calendar)

struct PaschalCalculator {
    static func easter(year: Int) -> Date {
        let a = year % 4
        let b = year % 7
        let c = year % 19
        let d = (19 * c + 15) % 30
        let e = (2 * a + 4 * b - d + 34) % 7
        let month = (d + e + 114) / 31
        let day = ((d + e + 114) % 31) + 1

        let julianToGregorianOffset = julianOffset(year: year)

        // Calendar.date(from:) automatically normalizes out-of-range values
        // (e.g. April 38 → May 8), so no manual month overflow handling needed.
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day + julianToGregorianOffset

        return Calendar.current.date(from: components) ?? Date()
    }

    private static func julianOffset(year: Int) -> Int {
        // Julian-to-Gregorian offset grows by 1 day each century year
        // not divisible by 400 (e.g. 1900→13, 2100→14, but not 2000).
        let century = year / 100
        return century - century / 4 - 2
    }

    static func greatLentStart(year: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -48, to: easter(year: year))!
    }

    static func pentecost(year: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: 49, to: easter(year: year))!
    }

    static func ascension(year: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: 39, to: easter(year: year))!
    }
}

// MARK: - Calendar Helpers

struct LiturgicalCalendar {
    static let monthNames = [
        "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
        "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"
    ]

    static func fallbackFastingLevel(for date: Date) -> LiturgicalDay.FastingLevel {
        let calendar = Calendar.current
        let dow = calendar.component(.weekday, from: date)
        let year = calendar.component(.year, from: date)
        let easter = PaschalCalculator.easter(year: year)
        let lentStart = PaschalCalculator.greatLentStart(year: year)
        let isGreatLent = date >= lentStart && date < easter

        if isGreatLent { return .strict }
        if dow == 4 || dow == 6 { return .regular }
        return .none
    }

    static func isSunday(_ date: Date) -> Bool {
        Calendar.current.component(.weekday, from: date) == 1
    }
}
