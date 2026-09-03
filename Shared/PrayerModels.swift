import Foundation

// MARK: - Молитвослов

struct PrayerCategory: Identifiable, Hashable {
    let id: Int
    let slug: String
    let title: String
    let subtitle: String?
    let icon: String?
    let sortOrder: Int
    /// Последование: молитвы читаются подряд, как в печатном молитвослове.
    let isSequence: Bool
}

/// Лёгкая строка списка — без текстов молитвы.
struct PrayerSummary: Identifiable, Hashable {
    let id: Int
    let slug: String
    let title: String
    let subtitle: String?
    let takesNames: Bool
}

/// Результат поиска молитвы — с названием раздела для контекста.
///
/// `subtitle`/`kind` — добавлены для интент-поиска (search_design.md §3.5).
/// `kind == .category` — это не молитва, а раздел, отвечающий на запрос
/// целиком (например, «утром» → раздел «Утренние молитвы»); в этом случае
/// `id`/`slug`/`title` описывают раздел (slug раздела, а не молитвы).
struct PrayerSearchResult: Identifiable, Hashable {
    enum Kind: Hashable {
        case prayer
        case category(slug: String)
    }

    let id: Int
    let slug: String
    let title: String
    let categoryTitle: String
    var subtitle: String? = nil
    var kind: Kind = .prayer
}

struct Prayer: Identifiable, Hashable {
    let id: Int
    let slug: String
    let categorySlug: String
    let title: String
    let subtitle: String?
    let textCS: String
    let textRU: String?
    let takesNames: Bool
    let nameCase: NameCase?
    let nameList: PomyannikList?
}

/// Падеж, в котором имена вставляются в молитву.
enum NameCase: String {
    case genitive = "gen"
    case accusative = "acc"
}

// MARK: - Помянник

enum PomyannikList: String, CaseIterable, Identifiable {
    case health = "health"   // О здравии
    case repose = "repose"   // О упокоении

    var id: String { rawValue }

    var title: String {
        switch self {
        case .health: return "О здравии"
        case .repose: return "О упокоении"
        }
    }
}

enum PersonGender: String {
    case male = "m"
    case female = "f"
}

/// Статус поминаемого в записке («болящего Георгия», «новопреставленной Фотинии»).
/// Хранится код; отображаемые формы зависят от пола.
enum PomyannikStatus: String, CaseIterable, Identifiable {
    // О здравии
    case sick = "sick"                 // болящий
    case traveling = "traveling"       // путешествующий
    case warrior = "warrior"           // воин
    case infant = "infant"             // младенец (до 7 лет)
    case child = "child"               // отрок / отроковица (7–14 лет)
    case expecting = "expecting"       // непраздная (беременная)
    // О упокоении
    case newlyDeparted = "newlyDeparted"   // новопреставленный (до 40 дней)
    case everRemembered = "everRemembered" // приснопамятный (годовщина)

    var id: String { rawValue }

    /// Статусы, доступные для списка.
    static func statuses(for list: PomyannikList) -> [PomyannikStatus] {
        switch list {
        case .health: return [.sick, .traveling, .warrior, .infant, .child, .expecting]
        case .repose: return [.newlyDeparted, .everRemembered, .warrior, .infant, .child]
        }
    }

    /// Именительный падеж — для выбора в интерфейсе.
    func title(for gender: PersonGender) -> String {
        switch (self, gender) {
        case (.sick, .male):            return "болящий"
        case (.sick, .female):          return "болящая"
        case (.traveling, .male):       return "путешествующий"
        case (.traveling, .female):     return "путешествующая"
        case (.warrior, _):             return "воин"
        case (.infant, _):              return "младенец"
        case (.child, .male):           return "отрок"
        case (.child, .female):         return "отроковица"
        case (.expecting, _):           return "непраздная"
        case (.newlyDeparted, .male):   return "новопреставленный"
        case (.newlyDeparted, .female): return "новопреставленная"
        case (.everRemembered, .male):  return "приснопамятный"
        case (.everRemembered, .female): return "приснопамятная"
        }
    }

    /// Родительный падеж — для записки («о здравии болящего Георгия»).
    func genitive(for gender: PersonGender) -> String {
        switch (self, gender) {
        case (.sick, .male):            return "болящего"
        case (.sick, .female):          return "болящей"
        case (.traveling, .male):       return "путешествующего"
        case (.traveling, .female):     return "путешествующей"
        case (.warrior, _):             return "воина"
        case (.infant, _):              return "младенца"
        case (.child, .male):           return "отрока"
        case (.child, .female):         return "отроковицы"
        case (.expecting, _):           return "непраздной"
        case (.newlyDeparted, .male):   return "новопреставленного"
        case (.newlyDeparted, .female): return "новопреставленной"
        case (.everRemembered, .male):  return "приснопамятного"
        case (.everRemembered, .female): return "приснопамятной"
        }
    }
}
