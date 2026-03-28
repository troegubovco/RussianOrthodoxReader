import Foundation
import SQLite3

nonisolated protocol BibleRepositoryProtocol {
    var books: [BibleBook] { get }
    func books(for testament: Testament) -> [BibleBook]
    func chapter(bookId: String, chapter: Int) -> BibleChapter?
    func verses(bookId: String, chapter: Int, range: ClosedRange<Int>?) -> [BibleVerse]
    func hasChapter(bookId: String) -> Bool
    func firstAvailableChapter(bookId: String) -> String?
}

nonisolated final class BibleSQLiteRepository: BibleRepositoryProtocol, @unchecked Sendable {
    static let shared = BibleSQLiteRepository()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private(set) var books: [BibleBook] = []
    private var bookIdSet: Set<String> = []
    private(set) var bookById: [String: BibleBook] = [:]
    private var chapterCache: [String: BibleChapter] = [:]

    private init() {
        openDatabase()
        books = loadBooksFromDatabase() ?? Self.fallbackBooks
        bookIdSet = Set(books.map(\.id))
        bookById = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func books(for testament: Testament) -> [BibleBook] {
        books.filter { $0.testament == testament }
    }

    func chapter(bookId: String, chapter: Int) -> BibleChapter? {
        let key = BibleDataProvider.chapterKey(bookId: bookId, chapter: chapter)

        lock.lock()
        if let cached = chapterCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let chapterVerses = verses(bookId: bookId, chapter: chapter, range: nil)
        guard !chapterVerses.isEmpty else { return nil }

        let bookName = bookById[bookId]?.name ?? bookId.uppercased()
        let result = BibleChapter(
            id: key,
            bookId: bookId,
            bookName: bookName,
            chapter: chapter,
            verses: chapterVerses
        )

        lock.lock()
        chapterCache[key] = result
        lock.unlock()

        return result
    }

    func verses(bookId: String, chapter: Int, range: ClosedRange<Int>?) -> [BibleVerse] {
        let dbVerses = selectVerses(bookId: bookId, chapter: chapter, range: range)
        if !dbVerses.isEmpty {
            return dbVerses
        }

        let fallback = fallbackVerses(bookId: bookId, chapter: chapter)
        guard !fallback.isEmpty else {
            if range != nil {
                return []
            }
            return [
                BibleVerse(
                    id: 1,
                    number: 1,
                    synodal: "Текст главы \(chapter) книги \(bookId.uppercased()) отсутствует в bundled базе. Запустите Tools/build_bible_db/build.sh для генерации полного корпуса."
                )
            ]
        }

        if let range {
            return fallback.filter { range.contains($0.number) }
        }
        return fallback
    }

    func hasChapter(bookId: String) -> Bool {
        bookIdSet.contains(bookId)
    }

    func firstAvailableChapter(bookId: String) -> String? {
        guard let book = bookById[bookId] else { return nil }
        let chapter = 1
        return BibleDataProvider.chapterKey(bookId: book.id, chapter: chapter)
    }

    private func openDatabase() {
        let candidates = [
            Bundle.main.url(forResource: "rus_synodal", withExtension: "sqlite", subdirectory: "Bible"),
            Bundle.main.url(forResource: "rus_synodal", withExtension: "sqlite"),
            Bundle.main.url(forResource: "rus_synodal", withExtension: "sqlite", subdirectory: "Resources/Bible")
        ]

        guard let url = candidates.compactMap({ $0 }).first else {
            #if DEBUG
            print("[BibleSQLiteRepository] rus_synodal.sqlite not found in app bundle")
            #endif
            return
        }

        var connection: OpaquePointer?
        if sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = connection
        } else {
            #if DEBUG
            if let connection, let cString = sqlite3_errmsg(connection) {
                print("[BibleSQLiteRepository] sqlite open error: \(String(cString: cString))")
            }
            #endif
            if let connection {
                sqlite3_close(connection)
            }
        }
    }

    private func loadBooksFromDatabase() -> [BibleBook]? {
        guard let db else { return nil }

        let sql = """
        SELECT book_id, name_ru, abbr_ru, testament, chapter_count
        FROM books
        ORDER BY order_index ASC
        """

        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var loaded: [BibleBook] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(statement, 0),
                let namePtr = sqlite3_column_text(statement, 1),
                let abbrPtr = sqlite3_column_text(statement, 2),
                let testamentPtr = sqlite3_column_text(statement, 3)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let name = String(cString: namePtr)
            let abbreviation = String(cString: abbrPtr)
            let testamentRaw = String(cString: testamentPtr).lowercased()
            let chapterCount = Int(sqlite3_column_int(statement, 4))

            let testament: Testament
            if testamentRaw == "new" || testamentRaw == "nt" {
                testament = .new
            } else {
                testament = .old
            }

            loaded.append(
                BibleBook(
                    id: id,
                    name: name,
                    abbreviation: abbreviation,
                    testament: testament,
                    chapterCount: chapterCount
                )
            )
        }

        return loaded.isEmpty ? nil : loaded
    }

    private func selectVerses(bookId: String, chapter: Int, range: ClosedRange<Int>?) -> [BibleVerse] {
        guard let db else { return [] }

        let sql: String
        if range != nil {
            sql = """
            SELECT verse, synodal_text
            FROM verses
            WHERE book_id = ? AND chapter = ? AND verse BETWEEN ? AND ?
            ORDER BY verse ASC
            """
        } else {
            sql = """
            SELECT verse, synodal_text
            FROM verses
            WHERE book_id = ? AND chapter = ?
            ORDER BY verse ASC
            """
        }

        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (bookId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(chapter))
        if let range {
            sqlite3_bind_int(statement, 3, Int32(range.lowerBound))
            sqlite3_bind_int(statement, 4, Int32(range.upperBound))
        }

        var result: [BibleVerse] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let verse = Int(sqlite3_column_int(statement, 0))
            guard let textPtr = sqlite3_column_text(statement, 1) else { continue }
            let text = sanitizeVerseText(String(cString: textPtr))
            result.append(BibleVerse(id: verse, number: verse, synodal: text))
        }

        return result
    }

    private func fallbackVerses(bookId: String, chapter: Int) -> [BibleVerse] {
        (Self.fallbackChapterVerses["\(bookId)-\(chapter)"] ?? []).map {
            BibleVerse(id: $0.id, number: $0.number, synodal: sanitizeVerseText($0.synodal))
        }
    }

    private func sanitizeVerseText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "\\s*\\[[0-9]+\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let fallbackChapterVerses: [String: [BibleVerse]] = [
        "mat-5": [
            BibleVerse(id: 1, number: 1, synodal: "Увидев народ, Он взошел на гору; и, когда сел, приступили к Нему ученики Его."),
            BibleVerse(id: 2, number: 2, synodal: "И Он, отверзши уста Свои, учил их, говоря:"),
            BibleVerse(id: 3, number: 3, synodal: "Блаженны нищие духом, ибо их есть Царство Небесное."),
            BibleVerse(id: 4, number: 4, synodal: "Блаженны плачущие, ибо они утешатся.")
        ],
        "joh-1": [
            BibleVerse(id: 1, number: 1, synodal: "В начале было Слово, и Слово было у Бога, и Слово было Бог."),
            BibleVerse(id: 2, number: 2, synodal: "Оно было в начале у Бога."),
            BibleVerse(id: 3, number: 3, synodal: "Все чрез Него начало быть, и без Него ничто не начало быть, что начало быть."),
            BibleVerse(id: 4, number: 4, synodal: "В Нем была жизнь, и жизнь была свет человеков.")
        ],
        "psa-50": [
            BibleVerse(id: 1, number: 1, synodal: "Начальнику хора. Псалом Давида,"),
            BibleVerse(id: 2, number: 2, synodal: "когда приходил к нему пророк Нафан, после того, как Давид вошел к Вирсавии."),
            BibleVerse(id: 3, number: 3, synodal: "Помилуй меня, Боже, по великой милости Твоей, и по множеству щедрот Твоих изгладь беззакония мои.")
        ]
    ]

    static let fallbackBooks: [BibleBook] = [
        // Ветхий Завет (39)
        BibleBook(id: "gen", name: "Бытие", abbreviation: "Быт", testament: .old, chapterCount: 50),
        BibleBook(id: "exo", name: "Исход", abbreviation: "Исх", testament: .old, chapterCount: 40),
        BibleBook(id: "lev", name: "Левит", abbreviation: "Лев", testament: .old, chapterCount: 27),
        BibleBook(id: "num", name: "Числа", abbreviation: "Чис", testament: .old, chapterCount: 36),
        BibleBook(id: "deu", name: "Второзаконие", abbreviation: "Втор", testament: .old, chapterCount: 34),
        BibleBook(id: "jos", name: "Иисус Навин", abbreviation: "Нав", testament: .old, chapterCount: 24),
        BibleBook(id: "jdg", name: "Книга Судей", abbreviation: "Суд", testament: .old, chapterCount: 21),
        BibleBook(id: "rut", name: "Руфь", abbreviation: "Руф", testament: .old, chapterCount: 4),
        BibleBook(id: "1sa", name: "1-я Царств", abbreviation: "1Цар", testament: .old, chapterCount: 31),
        BibleBook(id: "2sa", name: "2-я Царств", abbreviation: "2Цар", testament: .old, chapterCount: 24),
        BibleBook(id: "1ki", name: "3-я Царств", abbreviation: "3Цар", testament: .old, chapterCount: 22),
        BibleBook(id: "2ki", name: "4-я Царств", abbreviation: "4Цар", testament: .old, chapterCount: 25),
        BibleBook(id: "1ch", name: "1-я Паралипоменон", abbreviation: "1Пар", testament: .old, chapterCount: 29),
        BibleBook(id: "2ch", name: "2-я Паралипоменон", abbreviation: "2Пар", testament: .old, chapterCount: 36),
        BibleBook(id: "ezr", name: "Ездры", abbreviation: "Ездр", testament: .old, chapterCount: 10),
        BibleBook(id: "neh", name: "Неемии", abbreviation: "Неем", testament: .old, chapterCount: 13),
        BibleBook(id: "est", name: "Есфирь", abbreviation: "Есф", testament: .old, chapterCount: 10),
        BibleBook(id: "job", name: "Иов", abbreviation: "Иов", testament: .old, chapterCount: 42),
        BibleBook(id: "psa", name: "Псалтирь", abbreviation: "Пс", testament: .old, chapterCount: 150),
        BibleBook(id: "pro", name: "Притчи", abbreviation: "Притч", testament: .old, chapterCount: 31),
        BibleBook(id: "ecc", name: "Екклесиаст", abbreviation: "Еккл", testament: .old, chapterCount: 12),
        BibleBook(id: "sng", name: "Песнь Песней", abbreviation: "Песн", testament: .old, chapterCount: 8),
        BibleBook(id: "isa", name: "Исаия", abbreviation: "Ис", testament: .old, chapterCount: 66),
        BibleBook(id: "jer", name: "Иеремия", abbreviation: "Иер", testament: .old, chapterCount: 52),
        BibleBook(id: "lam", name: "Плач Иеремии", abbreviation: "Плач", testament: .old, chapterCount: 5),
        BibleBook(id: "eze", name: "Иезекииль", abbreviation: "Иез", testament: .old, chapterCount: 48),
        BibleBook(id: "dan", name: "Даниил", abbreviation: "Дан", testament: .old, chapterCount: 12),
        BibleBook(id: "hos", name: "Осия", abbreviation: "Ос", testament: .old, chapterCount: 14),
        BibleBook(id: "jol", name: "Иоиль", abbreviation: "Иоил", testament: .old, chapterCount: 3),
        BibleBook(id: "amo", name: "Амос", abbreviation: "Ам", testament: .old, chapterCount: 9),
        BibleBook(id: "oba", name: "Авдий", abbreviation: "Авд", testament: .old, chapterCount: 1),
        BibleBook(id: "jon", name: "Иона", abbreviation: "Ион", testament: .old, chapterCount: 4),
        BibleBook(id: "mic", name: "Михей", abbreviation: "Мих", testament: .old, chapterCount: 7),
        BibleBook(id: "nam", name: "Наум", abbreviation: "Наум", testament: .old, chapterCount: 3),
        BibleBook(id: "hab", name: "Аввакум", abbreviation: "Авв", testament: .old, chapterCount: 3),
        BibleBook(id: "zep", name: "Софония", abbreviation: "Соф", testament: .old, chapterCount: 3),
        BibleBook(id: "hag", name: "Аггей", abbreviation: "Агг", testament: .old, chapterCount: 2),
        BibleBook(id: "zac", name: "Захария", abbreviation: "Зах", testament: .old, chapterCount: 14),
        BibleBook(id: "mal", name: "Малахия", abbreviation: "Мал", testament: .old, chapterCount: 4),

        // Неканонические / второканонические (11)
        BibleBook(id: "1es", name: "1-я Ездры", abbreviation: "1Езд", testament: .old, chapterCount: 10),
        BibleBook(id: "2es", name: "2-я Ездры", abbreviation: "2Езд", testament: .old, chapterCount: 16),
        BibleBook(id: "tob", name: "Товита", abbreviation: "Тов", testament: .old, chapterCount: 14),
        BibleBook(id: "jdt", name: "Иудифь", abbreviation: "Иудф", testament: .old, chapterCount: 16),
        BibleBook(id: "wis", name: "Премудрости Соломона", abbreviation: "Прем", testament: .old, chapterCount: 19),
        BibleBook(id: "sir", name: "Иисуса, сына Сирахова", abbreviation: "Сир", testament: .old, chapterCount: 51),
        BibleBook(id: "bar", name: "Варуха", abbreviation: "Вар", testament: .old, chapterCount: 6),
        BibleBook(id: "epj", name: "Послание Иеремии", abbreviation: "ПослИер", testament: .old, chapterCount: 1),
        BibleBook(id: "1ma", name: "1-я Маккавейская", abbreviation: "1Мак", testament: .old, chapterCount: 16),
        BibleBook(id: "2ma", name: "2-я Маккавейская", abbreviation: "2Мак", testament: .old, chapterCount: 15),
        BibleBook(id: "3ma", name: "3-я Маккавейская", abbreviation: "3Мак", testament: .old, chapterCount: 7),

        // Новый Завет (27)
        BibleBook(id: "mat", name: "От Матфея", abbreviation: "Мф", testament: .new, chapterCount: 28),
        BibleBook(id: "mar", name: "От Марка", abbreviation: "Мк", testament: .new, chapterCount: 16),
        BibleBook(id: "luk", name: "От Луки", abbreviation: "Лк", testament: .new, chapterCount: 24),
        BibleBook(id: "joh", name: "От Иоанна", abbreviation: "Ин", testament: .new, chapterCount: 21),
        BibleBook(id: "act", name: "Деяния", abbreviation: "Деян", testament: .new, chapterCount: 28),
        BibleBook(id: "rom", name: "К Римлянам", abbreviation: "Рим", testament: .new, chapterCount: 16),
        BibleBook(id: "1co", name: "1-е Коринфянам", abbreviation: "1Кор", testament: .new, chapterCount: 16),
        BibleBook(id: "2co", name: "2-е Коринфянам", abbreviation: "2Кор", testament: .new, chapterCount: 13),
        BibleBook(id: "gal", name: "К Галатам", abbreviation: "Гал", testament: .new, chapterCount: 6),
        BibleBook(id: "eph", name: "К Ефесянам", abbreviation: "Еф", testament: .new, chapterCount: 6),
        BibleBook(id: "phi", name: "К Филиппийцам", abbreviation: "Флп", testament: .new, chapterCount: 4),
        BibleBook(id: "col", name: "К Колоссянам", abbreviation: "Кол", testament: .new, chapterCount: 4),
        BibleBook(id: "1th", name: "1-е Фессалоникийцам", abbreviation: "1Фес", testament: .new, chapterCount: 5),
        BibleBook(id: "2th", name: "2-е Фессалоникийцам", abbreviation: "2Фес", testament: .new, chapterCount: 3),
        BibleBook(id: "1ti", name: "1-е Тимофею", abbreviation: "1Тим", testament: .new, chapterCount: 6),
        BibleBook(id: "2ti", name: "2-е Тимофею", abbreviation: "2Тим", testament: .new, chapterCount: 4),
        BibleBook(id: "tit", name: "К Титу", abbreviation: "Тит", testament: .new, chapterCount: 3),
        BibleBook(id: "phm", name: "К Филимону", abbreviation: "Флм", testament: .new, chapterCount: 1),
        BibleBook(id: "heb", name: "К Евреям", abbreviation: "Евр", testament: .new, chapterCount: 13),
        BibleBook(id: "jas", name: "Иакова", abbreviation: "Иак", testament: .new, chapterCount: 5),
        BibleBook(id: "1pe", name: "1-е Петра", abbreviation: "1Пет", testament: .new, chapterCount: 5),
        BibleBook(id: "2pe", name: "2-е Петра", abbreviation: "2Пет", testament: .new, chapterCount: 3),
        BibleBook(id: "1jo", name: "1-е Иоанна", abbreviation: "1Ин", testament: .new, chapterCount: 5),
        BibleBook(id: "2jo", name: "2-е Иоанна", abbreviation: "2Ин", testament: .new, chapterCount: 1),
        BibleBook(id: "3jo", name: "3-е Иоанна", abbreviation: "3Ин", testament: .new, chapterCount: 1),
        BibleBook(id: "jud", name: "Иуды", abbreviation: "Иуд", testament: .new, chapterCount: 1),
        BibleBook(id: "rev", name: "Откровение", abbreviation: "Откр", testament: .new, chapterCount: 22)
    ]
}
