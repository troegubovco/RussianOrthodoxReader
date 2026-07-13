import Foundation
import SQLite3

/// Доступ к встроенной базе молитвослова (prayers.sqlite).
/// Read-only, потокобезопасно (NSLock), по образцу DictionaryRepository.
final class PrayersRepository {
    static let shared = PrayersRepository()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private var cachedCategories: [PrayerCategory]?

    private init() {
        openDatabase()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    var isAvailable: Bool { db != nil }

    // MARK: - Public API

    func categories() -> [PrayerCategory] {
        if let cachedCategories { return cachedCategories }
        guard let db else { return [] }
        let sql = """
        SELECT id, slug, title, subtitle, icon, sort_order, is_sequence
        FROM categories
        WHERE parent_id IS NULL
        ORDER BY sort_order
        """
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [PrayerCategory] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(PrayerCategory(
                id: Int(sqlite3_column_int(stmt, 0)),
                slug: columnText(stmt, 1) ?? "",
                title: columnText(stmt, 2) ?? "",
                subtitle: columnText(stmt, 3),
                icon: columnText(stmt, 4),
                sortOrder: Int(sqlite3_column_int(stmt, 5)),
                isSequence: sqlite3_column_int(stmt, 6) != 0
            ))
        }
        cachedCategories = result
        return result
    }

    /// Подкатегории раздела (например, «Ежедневное правило» → утренние, вечерние…).
    func subcategories(of categoryID: Int) -> [PrayerCategory] {
        guard let db else { return [] }
        let sql = """
        SELECT id, slug, title, subtitle, icon, sort_order, is_sequence
        FROM categories WHERE parent_id = ? ORDER BY sort_order
        """
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(categoryID))
        var result: [PrayerCategory] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(PrayerCategory(
                id: Int(sqlite3_column_int(stmt, 0)),
                slug: columnText(stmt, 1) ?? "",
                title: columnText(stmt, 2) ?? "",
                subtitle: columnText(stmt, 3),
                icon: columnText(stmt, 4),
                sortOrder: Int(sqlite3_column_int(stmt, 5)),
                isSequence: sqlite3_column_int(stmt, 6) != 0
            ))
        }
        return result
    }

    /// Полные тексты всех молитв категории по порядку — для сквозного чтения.
    func fullPrayers(inCategory categorySlug: String) -> [Prayer] {
        guard let db else { return [] }
        let sql = prayerSelectSQL + " WHERE c.slug = ? ORDER BY p.sort_order"
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (categorySlug as NSString).utf8String, -1, nil)
        var result: [Prayer] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(readPrayer(stmt))
        }
        return result
    }

    func prayers(inCategory categorySlug: String) -> [PrayerSummary] {
        guard let db else { return [] }
        let sql = """
        SELECT p.id, p.slug, p.title, p.subtitle, p.takes_names
        FROM prayers p JOIN categories c ON c.id = p.category_id
        WHERE c.slug = ?
        ORDER BY p.sort_order
        """
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (categorySlug as NSString).utf8String, -1, nil)
        var result: [PrayerSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(PrayerSummary(
                id: Int(sqlite3_column_int(stmt, 0)),
                slug: columnText(stmt, 1) ?? "",
                title: columnText(stmt, 2) ?? "",
                subtitle: columnText(stmt, 3),
                takesNames: sqlite3_column_int(stmt, 4) != 0
            ))
        }
        return result
    }

    func prayer(slug: String) -> Prayer? {
        guard let db else { return nil }
        let sql = prayerSelectSQL + " WHERE p.slug = ? LIMIT 1"
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (slug as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readPrayer(stmt)
    }

    /// Молитвы по списку slug'ов (для закладок), в переданном порядке.
    func prayers(slugs: [String]) -> [Prayer] {
        var result: [Prayer] = []
        for slug in slugs {
            if let p = prayer(slug: slug) { result.append(p) }
        }
        return result
    }

    /// Поиск по названиям и текстам молитв. Нечувствителен к ударениям и ё/е
    /// (использует предвычисленные колонки title_plain / search_text).
    /// Совпадения в названии — первыми.
    func search(query: String) -> [PrayerSearchResult] {
        guard let db else { return [] }
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
        guard normalized.count >= 2 else { return [] }

        let sql = """
        SELECT p.id, p.slug, p.title, c.title,
               CASE WHEN p.title_plain LIKE ? THEN 0 ELSE 1 END AS rank
        FROM prayers p JOIN categories c ON c.id = p.category_id
        WHERE p.search_text LIKE ?
        ORDER BY rank, p.sort_order
        LIMIT 50
        """
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(normalized)%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (pattern as NSString).utf8String, -1, nil)
        var result: [PrayerSearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(PrayerSearchResult(
                id: Int(sqlite3_column_int(stmt, 0)),
                slug: columnText(stmt, 1) ?? "",
                title: columnText(stmt, 2) ?? "",
                categoryTitle: columnText(stmt, 3) ?? ""
            ))
        }
        return result
    }

    // MARK: - Private

    private let prayerSelectSQL = """
    SELECT p.id, p.slug, c.slug, p.title, p.subtitle, p.text_cs, p.text_ru,
           p.takes_names, p.name_case, p.name_list
    FROM prayers p JOIN categories c ON c.id = p.category_id
    """

    private func readPrayer(_ stmt: OpaquePointer?) -> Prayer {
        Prayer(
            id: Int(sqlite3_column_int(stmt, 0)),
            slug: columnText(stmt, 1) ?? "",
            categorySlug: columnText(stmt, 2) ?? "",
            title: columnText(stmt, 3) ?? "",
            subtitle: columnText(stmt, 4),
            textCS: columnText(stmt, 5) ?? "",
            textRU: columnText(stmt, 6),
            takesNames: sqlite3_column_int(stmt, 7) != 0,
            nameCase: columnText(stmt, 8).flatMap(NameCase.init(rawValue:)),
            nameList: columnText(stmt, 9).flatMap(PomyannikList.init(rawValue:))
        )
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    private func openDatabase() {
        let candidates = [
            Bundle.main.url(forResource: "prayers", withExtension: "sqlite"),
            Bundle.main.url(forResource: "prayers", withExtension: "sqlite",
                            subdirectory: "Resources"),
            Bundle.main.url(forResource: "prayers", withExtension: "sqlite",
                            subdirectory: "Bible")
        ]
        guard let url = candidates.compactMap({ $0 }).first else { return }
        var connection: OpaquePointer?
        if sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = connection
        } else {
            if let connection { sqlite3_close(connection) }
        }
    }
}
