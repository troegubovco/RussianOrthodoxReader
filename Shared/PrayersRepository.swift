import Foundation
import SQLite3

/// Доступ к встроенной базе молитвослова (prayers.sqlite).
/// Read-only, потокобезопасно (NSLock), по образцу DictionaryRepository.
final class PrayersRepository {
    static let shared = PrayersRepository()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private var cachedCategories: [PrayerCategory]?

    // MARK: - Поиск: интент-состояние (search_design.md §3.6)
    //
    // Все три — lazy, вычисляются один раз при первом обращении к search(query:),
    // под тем же lock'ом (первый вызов search(query:) уже держит lock, поэтому
    // сами загрузчики НЕ берут lock повторно — NSLock не реентерабелен).
    private lazy var hasFTS: Bool = probeFTS()
    private lazy var synonyms: [String: [String]] = loadSynonyms()
    private lazy var stopStems: Set<String> = loadStopwords()
    /// (категория, стемы её тегов из category_tags.tags_s) — 13–15 строк, весь список.
    private lazy var categoryTags: [(category: PrayerCategory, tagStems: Set<String>)] = loadCategoryTags()

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

    /// Категория по slug'у — верхнего уровня или подкатегория. Используется
    /// для навигации из результатов поиска (Tier 2, см. search(query:)).
    func category(slug: String) -> PrayerCategory? {
        if let match = categories().first(where: { $0.slug == slug }) { return match }
        for parent in categories() {
            if let match = subcategories(of: parent.id).first(where: { $0.slug == slug }) {
                return match
            }
        }
        return nil
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

    /// UserDefaults-ключ, включающий женскую форму молитв в последовании ко
    /// Причащению и в благодарственных молитвах. Общий для iPhone и watch.
    static let feminineFormsKey = "prayerFeminineForms"

    /// Полные тексты молитв категории с учётом мужской/женской формы.
    ///
    /// В разделах «Последование ко Причащению» и «Благодарственные молитвы»
    /// каждая молитва встречается в базе дважды: мужской вариант со slug'ом
    /// `X` и женский вариант со slug'ом `X-2` (его подзаголовок оканчивается
    /// на «· женская форма»). Этот метод оставляет только нужный вариант,
    /// сохраняя исходный порядок. Молитвы без парного slug'а (например,
    /// общий для обеих форм фрагмент, у которого нет пары `-2`/без `-2`)
    /// не фильтруются и остаются в обоих случаях.
    func fullPrayers(inCategory categorySlug: String, feminine: Bool) -> [Prayer] {
        let all = fullPrayers(inCategory: categorySlug)
        let slugs = Set(all.map(\.slug))
        return all.filter { p in
            if p.slug.hasSuffix("-2"), slugs.contains(String(p.slug.dropLast(2))) {
                return feminine
            } else if slugs.contains(p.slug + "-2") {
                return !feminine
            } else {
                return true
            }
        }
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

    /// Интент-поиск по названиям, подзаголовкам, ситуативным тегам и текстам
    /// молитв (search_design.md §3). Совмещает точную подстроку (Tier 0/1/5 —
    /// то, что работает сегодня, и продолжает работать без изменений) со
    /// стемминговым FTS5-поиском (Tier 3/4) и разделами-ответами (Tier 2,
    /// первые элементы результата, kind == .category). При недоступности FTS5
    /// (hasFTS == false) тихо откатывается к Tier 0/1/5.
    func search(query: String) -> [PrayerSearchResult] {
        guard db != nil else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased().replacingOccurrences(of: "ё", with: "е")
        guard normalized.count >= 2 else { return [] }

        lock.lock()
        defer { lock.unlock() }

        // Tier 0/1/5 — точная подстрока. Гарантия совместимости: работает
        // независимо от FTS5 и от качества стемминга/тегов.
        var candidates: [Int: Candidate] = [:]
        for c in searchExactLocked(normalized) {
            candidates[c.result.id] = c
        }

        // Tier 2/3/4 — интент-поиск поверх стеммированного индекса.
        var categoryResults: [PrayerSearchResult] = []
        if hasFTS {
            let tokens = SearchNormalizer.tokens(trimmed)
            if !tokens.isEmpty {
                let stems = tokens.map(SearchNormalizer.surfaceStem)
                let nonStopwordTokens = zip(tokens, stems).filter { !stopStems.contains($0.1) }.map(\.0)
                // Stopwords are dropped only if at least one term survives — a
                // query of just "молитва" still has to search for something.
                let survivingTokens = nonStopwordTokens.isEmpty ? tokens : nonStopwordTokens
                let groups = survivingTokens
                    .map { SearchNormalizer.expand($0, conjugations: nil, synonyms: synonyms) }
                    .filter { !$0.isEmpty }

                if !groups.isEmpty {
                    let allStems = Set(groups.flatMap { $0 })
                    categoryResults = searchCategoriesLocked(allStems)
                    let coveredCategoryIds = Set(categoryResults.map(\.id))

                    for c in searchFTSLocked(groups: groups, suppressedCategoryIds: coveredCategoryIds) {
                        if let existing = candidates[c.result.id], existing.tier <= c.tier { continue }
                        candidates[c.result.id] = c
                    }
                }
            }
        }

        // Де-дубликация: «Отче наш» в main И morning, женские формы «-2» —
        // оставляем только каноническую копию (наименьший dup_rank в группе).
        var bestRankByGroup: [String: Int] = [:]
        for c in candidates.values {
            guard let g = c.dupGroup else { continue }
            bestRankByGroup[g] = min(bestRankByGroup[g] ?? .max, c.dupRank)
        }
        let deduped = candidates.values.filter { c in
            guard let g = c.dupGroup else { return true }
            return c.dupRank == (bestRankByGroup[g] ?? c.dupRank)
        }

        let prayers = deduped
            .sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                if a.score != b.score { return a.score < b.score }
                return a.sortOrder < b.sortOrder
            }
            .prefix(50)
            .map(\.result)

        return categoryResults + prayers
    }

    // MARK: - Поиск: внутреннее устройство

    /// Кандидат результата поиска до сортировки/де-дубликации.
    private struct Candidate {
        var tier: Int
        var score: Double
        var sortOrder: Int
        var dupGroup: String?
        var dupRank: Int
        var categoryId: Int
        var result: PrayerSearchResult
    }

    /// Tier 0 (точное совпадение заголовка) / 1 (заголовок содержит подстроку)
    /// / 5 (подстрока только в теле — сегодняшнее поведение по умолчанию).
    private func searchExactLocked(_ normalized: String) -> [Candidate] {
        guard let db else { return [] }
        let sql = """
        SELECT p.id, p.slug, p.title, p.subtitle, c.title, p.title_plain,
               p.dup_group, p.dup_rank, p.category_id, p.sort_order
        FROM prayers p JOIN categories c ON c.id = p.category_id
        WHERE p.search_text LIKE ?1
        ORDER BY p.sort_order
        LIMIT 50
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(normalized)%"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)

        var result: [Candidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let titlePlain = columnText(stmt, 5) ?? ""
            let tier: Int
            if titlePlain == normalized {
                tier = 0
            } else if titlePlain.contains(normalized) {
                tier = 1
            } else {
                tier = 5
            }
            result.append(Candidate(
                tier: tier,
                score: 0,
                sortOrder: Int(sqlite3_column_int(stmt, 9)),
                dupGroup: columnText(stmt, 6),
                dupRank: Int(sqlite3_column_int(stmt, 7)),
                categoryId: Int(sqlite3_column_int(stmt, 8)),
                result: PrayerSearchResult(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    slug: columnText(stmt, 1) ?? "",
                    title: columnText(stmt, 2) ?? "",
                    categoryTitle: columnText(stmt, 4) ?? "",
                    subtitle: columnText(stmt, 3)
                )
            ))
        }
        return result
    }

    /// Tier 3 (совпадение в title_s/subtitle_s/tags_s — заголовок, подзаголовок
    /// или СВОИ теги молитвы) / 4 (совпадение только в text_s — тело текста).
    /// Совпадение ТОЛЬКО в cat_tags_s (унаследованные теги раздела) отбрасывается,
    /// если этот раздел уже показан как Tier 2 (см. `suppressedCategoryIds`) —
    /// иначе «утром» печатает 25 утренних молитв поверх ответа-раздела.
    private func searchFTSLocked(groups: [[String]], suppressedCategoryIds: Set<Int>) -> [Candidate] {
        guard db != nil, let andExpr = ftsMatchExpression(groups: groups, op: "AND") else { return [] }

        var rows = runFTSQuery(andExpr)
        var usedExpr = andExpr
        if rows.count < 3, groups.count > 1, let orExpr = ftsMatchExpression(groups: groups, op: "OR") {
            rows = runFTSQuery(orExpr)
            usedExpr = orExpr
        }
        guard !rows.isEmpty else { return [] }

        let coreIds = matchingIds("{title_s subtitle_s tags_s} : (\(usedExpr))")
        let catIds = matchingIds("cat_tags_s : (\(usedExpr))")

        var result: [Candidate] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            let isCore = coreIds.contains(row.id)
            if !isCore, catIds.contains(row.id), suppressedCategoryIds.contains(row.categoryId) {
                continue
            }
            result.append(Candidate(
                tier: isCore ? 3 : 4,
                score: row.score,
                sortOrder: row.sortOrder,
                dupGroup: row.dupGroup,
                dupRank: row.dupRank,
                categoryId: row.categoryId,
                result: PrayerSearchResult(
                    id: row.id,
                    slug: row.slug,
                    title: row.title,
                    categoryTitle: row.categoryTitle,
                    subtitle: row.subtitle
                )
            ))
        }
        return result
    }

    private struct FTSRow {
        let id: Int, slug: String, title: String, subtitle: String?, categoryTitle: String
        let dupGroup: String?, dupRank: Int, categoryId: Int, sortOrder: Int, score: Double
    }

    /// `bm25(prayers_fts, 14.0, 7.0, 9.0, 2.5, 1.0)` — веса заголовок·подзаголовок·
    /// свои теги·теги раздела·текст (search_design.md §3.4). bm25 отрицателен;
    /// меньше = лучше, поэтому `ORDER BY score` без DESC — верно.
    private func runFTSQuery(_ match: String) -> [FTSRow] {
        guard let db else { return [] }
        let sql = """
        SELECT p.id, p.slug, p.title, p.subtitle, c.title, p.dup_group, p.dup_rank,
               p.category_id, p.sort_order, bm25(prayers_fts, 14.0, 7.0, 9.0, 2.5, 1.0) AS score
        FROM prayers_fts f
        JOIN prayers p ON p.id = f.rowid
        JOIN categories c ON c.id = p.category_id
        WHERE prayers_fts MATCH ?1
        ORDER BY score
        LIMIT 60
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (match as NSString).utf8String, -1, nil)
        var rows: [FTSRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(FTSRow(
                id: Int(sqlite3_column_int(stmt, 0)),
                slug: columnText(stmt, 1) ?? "",
                title: columnText(stmt, 2) ?? "",
                subtitle: columnText(stmt, 3),
                categoryTitle: columnText(stmt, 4) ?? "",
                dupGroup: columnText(stmt, 5),
                dupRank: Int(sqlite3_column_int(stmt, 6)),
                categoryId: Int(sqlite3_column_int(stmt, 7)),
                sortOrder: Int(sqlite3_column_int(stmt, 8)),
                score: sqlite3_column_double(stmt, 9)
            ))
        }
        return rows
    }

    /// rowid'ы (== prayers.id), совпавшие с `match` — используется с column-filter
    /// выражениями fts5 (`{col1 col2} : (…)`) для определения, КАКИЕ колонки дали
    /// совпадение, чтобы разделить Tier 3 / Tier 4 / подавляемый cat_tags_s-only хит.
    private func matchingIds(_ match: String) -> Set<Int> {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid FROM prayers_fts WHERE prayers_fts MATCH ?1",
                                  -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (match as NSString).utf8String, -1, nil)
        var ids: Set<Int> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.insert(Int(sqlite3_column_int(stmt, 0)))
        }
        return ids
    }

    /// `(a OR b OR c) AND (d OR e) AND …` — одна группа на переживший токен запроса.
    private func ftsMatchExpression(groups: [[String]], op: String) -> String? {
        guard !groups.isEmpty else { return nil }
        return groups
            .map { stems in "(" + stems.map { "\"\($0)\"" }.joined(separator: " OR ") + ")" }
            .joined(separator: " \(op) ")
    }

    /// Tier 2 — разделы, чьи теги (category_tags.tags_s) пересекаются с
    /// множеством стемов запроса. «утром» → «Утренние молитвы», без единой
    /// молитвы в первых экранах. Отсортировано по числу совпавших стемов.
    private func searchCategoriesLocked(_ queryStems: Set<String>) -> [PrayerSearchResult] {
        var hits: [(category: PrayerCategory, count: Int)] = []
        for entry in categoryTags {
            let count = queryStems.intersection(entry.tagStems).count
            if count > 0 {
                hits.append((entry.category, count))
            }
        }
        hits.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.category.sortOrder < b.category.sortOrder
        }
        return hits.map { hit in
            PrayerSearchResult(
                id: hit.category.id,
                slug: hit.category.slug,
                title: hit.category.title,
                categoryTitle: "",
                subtitle: hit.category.subtitle,
                kind: .category(slug: hit.category.slug)
            )
        }
    }

    /// `SELECT 1 FROM prayers_fts LIMIT 1` — если FTS5 недоступен/индекс битый/
    /// сборка старая, тихо остаёмся на Tier 0/1/5 (search_design.md §1).
    private func probeFTS() -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM prayers_fts LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        // A successful prepare already proves the FTS5 module and the table
        // both exist; stepping just confirms the query itself runs cleanly.
        let stepResult = sqlite3_step(stmt)
        return stepResult == SQLITE_ROW || stepResult == SQLITE_DONE
    }

    private func loadSynonyms() -> [String: [String]] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT term_stem, expansion_stem FROM search_synonyms",
                                  -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [String: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let term = columnText(stmt, 0), let expansion = columnText(stmt, 1) else { continue }
            result[term, default: []].append(expansion)
        }
        return result
    }

    /// Из БД (search_stopwords) — тот же список, что и
    /// `SearchNormalizer.stopStems`, но живёт вместе с данными. Если таблицы
    /// нет (старая сборка), откатываемся на константу из SearchNormalizer.
    private func loadStopwords() -> Set<String> {
        guard let db else { return SearchNormalizer.stopStems }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT stem FROM search_stopwords", -1, &stmt, nil) == SQLITE_OK else {
            return SearchNormalizer.stopStems
        }
        defer { sqlite3_finalize(stmt) }
        var result: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = columnText(stmt, 0) { result.insert(s) }
        }
        return result.isEmpty ? SearchNormalizer.stopStems : result
    }

    private func loadCategoryTags() -> [(category: PrayerCategory, tagStems: Set<String>)] {
        guard let db else { return [] }
        let sql = """
        SELECT c.id, c.slug, c.title, c.subtitle, c.icon, c.sort_order, c.is_sequence, ct.tags_s
        FROM category_tags ct JOIN categories c ON c.id = ct.category_id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [(category: PrayerCategory, tagStems: Set<String>)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let category = PrayerCategory(
                id: Int(sqlite3_column_int(stmt, 0)),
                slug: columnText(stmt, 1) ?? "",
                title: columnText(stmt, 2) ?? "",
                subtitle: columnText(stmt, 3),
                icon: columnText(stmt, 4),
                sortOrder: Int(sqlite3_column_int(stmt, 5)),
                isSequence: sqlite3_column_int(stmt, 6) != 0
            )
            let tagStems = Set((columnText(stmt, 7) ?? "").split(separator: " ").map(String.init))
            result.append((category, tagStems))
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

    #if DEBUG
    /// Prints the top 5 results for the search_design.md §3.7/§5 worked-example
    /// queries to stdout. Guarded by the `SINODAL_SEARCH_REPORT=1` env var at the
    /// call site (see RussianOrthodoxReaderApp.swift) — never runs otherwise.
    static func debugSearchReport() {
        let queries = [
            "когда болеет ребенок", "отче", "путь", "экзамен", "дорога",
            "николаю чудотворцу", "перед едой", "взбранной воеводе", "возлюбл",
        ]
        print("=== PrayersRepository.debugSearchReport (hasFTS=\(shared.hasFTS)) ===")
        fflush(stdout)
        for q in queries {
            let results = shared.search(query: q)
            print("\n--- \(q.debugDescription) ---")
            if results.isEmpty {
                print("  (пусто)")
            }
            for r in results.prefix(5) {
                switch r.kind {
                case .prayer:
                    print("  \(r.title) · \(r.categoryTitle)" + (r.subtitle.map { " — \($0)" } ?? ""))
                case .category:
                    print("  РАЗДЕЛ \(r.title)" + (r.subtitle.map { " — \($0)" } ?? ""))
                }
            }
            fflush(stdout)
        }
    }
    #endif
}
