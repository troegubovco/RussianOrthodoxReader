import Foundation

struct BookAliasMapper {
    static func bookId(for raw: String) -> String? {
        let key = normalize(raw)
        if let direct = aliases[key] {
            return direct
        }

        // Try removing spaces after numeric prefixes, e.g. "1 cor" -> "1cor"
        let compact = key.replacingOccurrences(of: " ", with: "")
        return aliases[compact]
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let aliases: [String: String] = [
        "genesis": "gen", "gen": "gen", "быт": "gen", "бытие": "gen",
        "exodus": "exo", "exo": "exo", "исх": "exo", "исход": "exo",
        "leviticus": "lev", "lev": "lev", "лев": "lev", "левит": "lev",
        "numbers": "num", "num": "num", "чис": "num", "числа": "num",
        "deuteronomy": "deu", "deu": "deu", "втор": "deu", "второзаконие": "deu",
        "joshua": "jos", "jos": "jos", "нав": "jos",
        "judges": "jdg", "jdg": "jdg", "суд": "jdg",
        "ruth": "rut", "rut": "rut", "руф": "rut",
        "1samuel": "1sa", "1 samuel": "1sa", "1sa": "1sa", "1цар": "1sa",
        "2samuel": "2sa", "2 samuel": "2sa", "2sa": "2sa", "2цар": "2sa",
        "1kings": "1ki", "1 kings": "1ki", "1ki": "1ki", "3цар": "1ki",
        "2kings": "2ki", "2 kings": "2ki", "2ki": "2ki", "4цар": "2ki",
        "psalms": "psa", "psalm": "psa", "ps": "psa", "psa": "psa", "пс": "psa", "псалтирь": "psa",
        "proverbs": "pro", "pro": "pro", "притч": "pro",
        "ecclesiastes": "ecc", "ecc": "ecc", "еккл": "ecc",
        "song of songs": "sng", "song": "sng", "sng": "sng", "песн": "sng",
        "isaiah": "isa", "isa": "isa", "ис": "isa", "исаия": "isa",
        "jeremiah": "jer", "jer": "jer", "иер": "jer",
        "lamentations": "lam", "lam": "lam", "плач": "lam",
        "ezekiel": "eze", "eze": "eze", "иез": "eze",
        "daniel": "dan", "dan": "dan", "дан": "dan",
        "hosea": "hos", "hos": "hos", "ос": "hos",
        "joel": "jol", "jol": "jol", "иоил": "jol",
        "amos": "amo", "amo": "amo", "ам": "amo",
        "obadiah": "oba", "oba": "oba", "авд": "oba",
        "jonah": "jon", "jon": "jon", "ион": "jon",
        "micah": "mic", "mic": "mic", "мих": "mic",
        "nahum": "nam", "nam": "nam", "наум": "nam",
        "habakkuk": "hab", "hab": "hab", "авв": "hab",
        "zephaniah": "zep", "zep": "zep", "соф": "zep",
        "haggai": "hag", "hag": "hag", "агг": "hag",
        "zechariah": "zac", "zac": "zac", "zec": "zac", "зах": "zac",
        "malachi": "mal", "mal": "mal", "мал": "mal",

        "matthew": "mat", "matt": "mat", "mat": "mat", "mt": "mat", "мф": "mat",
        "mark": "mar", "mar": "mar", "mrk": "mar", "mk": "mar", "мк": "mar",
        "luke": "luk", "luk": "luk", "lk": "luk", "лк": "luk",
        "john": "joh", "joh": "joh", "jhn": "joh", "jn": "joh", "ин": "joh",
        "acts": "act", "act": "act", "деян": "act",
        "romans": "rom", "rom": "rom", "рим": "rom",
        "1corinthians": "1co", "1 corinthians": "1co", "1co": "1co", "1кор": "1co",
        "2corinthians": "2co", "2 corinthians": "2co", "2co": "2co", "2кор": "2co",
        "galatians": "gal", "gal": "gal", "гал": "gal",
        "ephesians": "eph", "eph": "eph", "еф": "eph",
        "philippians": "phi", "phil": "phi", "phi": "phi", "флп": "phi",
        "colossians": "col", "col": "col", "кол": "col",
        "1thessalonians": "1th", "1 thessalonians": "1th", "1th": "1th", "1фес": "1th",
        "2thessalonians": "2th", "2 thessalonians": "2th", "2th": "2th", "2фес": "2th",
        "1timothy": "1ti", "1 timothy": "1ti", "1ti": "1ti", "1тим": "1ti",
        "2timothy": "2ti", "2 timothy": "2ti", "2ti": "2ti", "2тим": "2ti",
        "titus": "tit", "tit": "tit", "тит": "tit",
        "philemon": "phm", "phm": "phm", "флм": "phm",
        "hebrews": "heb", "heb": "heb", "евр": "heb",
        "james": "jas", "jas": "jas", "иак": "jas",
        "1peter": "1pe", "1 peter": "1pe", "1pe": "1pe", "1пет": "1pe",
        "2peter": "2pe", "2 peter": "2pe", "2pe": "2pe", "2пет": "2pe",
        "1john": "1jo", "1 john": "1jo", "1jo": "1jo", "1jn": "1jo", "1ин": "1jo",
        "2john": "2jo", "2 john": "2jo", "2jo": "2jo", "2jn": "2jo", "2ин": "2jo",
        "3john": "3jo", "3 john": "3jo", "3jo": "3jo", "3jn": "3jo", "3ин": "3jo",
        "jude": "jud", "jud": "jud", "иуд": "jud",
        "revelation": "rev", "apocalypse": "rev", "rev": "rev", "откр": "rev",

        "tobit": "tob", "tob": "tob", "тов": "tob",
        "judith": "jdt", "jdt": "jdt", "иудифь": "jdt",
        "wisdom of solomon": "wis",
        "wisdom": "wis", "wis": "wis", "прем": "wis",
        "sirach": "sir", "ecclesiasticus": "sir", "sir": "sir", "сир": "sir",
        "baruch": "bar", "bar": "bar", "вар": "bar",
        "epistle of jeremiah": "epj", "letter of jeremiah": "epj", "epj": "epj",
        "1maccabees": "1ma", "1 maccabees": "1ma", "1ma": "1ma", "1мак": "1ma",
        "2maccabees": "2ma", "2 maccabees": "2ma", "2ma": "2ma", "2мак": "2ma",
        "3maccabees": "3ma", "3 maccabees": "3ma", "3ma": "3ma", "3мак": "3ma",
        "1esdras": "1es", "1 esdras": "1es", "1es": "1es", "1езд": "1es",
        "2esdras": "2es", "2 esdras": "2es", "2es": "2es", "2езд": "2es"
    ]
}

