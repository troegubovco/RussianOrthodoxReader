import Foundation
import SQLite3

// MARK: - Result models (search_design.md §5 step 10)

nonisolated struct BibleSearchResult: Identifiable, Hashable {
    let id: Int                    // verses.rowid
    let bookId: String
    let bookAbbreviation: String   // «Ин»
    let chapter: Int
    let verse: Int
    let displayRef: String         // «Ин 3:16»
    let text: String               // full verse, for snippet building
}

nonisolated struct BibleTopicResult: Identifiable, Hashable {
    let id: Int
    let title: String
    let displayRef: String
    let bookId: String
    let chapter: Int
    let verseStart: Int?
}

/// Bible full-text search: stemmed lexical index + conjugation-map dual
/// indexing + a curated topic index + reference-jump recognition (via
/// `BibleReferenceQuery`, kept separate). See search_design.md §4.
///
/// Opens `rus_synodal.sqlite` with its **own** READONLY connection and its
/// own `NSLock` — deliberately not shared with `BibleSQLiteRepository`, whose
/// lock is held across the (much heavier) whole-book chapter loads.
nonisolated final class BibleSearchRepository: @unchecked Sendable {
    static let shared = BibleSearchRepository()

    private var db: OpaquePointer?
    private let lock = NSLock()

    /// `db != nil && verses_fts probes cleanly` — graceful degradation per
    /// search_design.md §1: if this is false, callers must fall back to
    /// however Bible lookup worked before search existed (i.e. nothing —
    /// there was no Bible search before), never crash or show an error.
    private(set) var hasFTS: Bool = false

    /// form -> lemma, loaded once from `bible_conjugations` (trimmed at build
    /// time to forms that occur in the Synodal text — a few tens of thousands
    /// of rows, cheap to hold in memory for the life of the app). Loaded once
    /// in `init`, read-only afterwards, so no locking is needed to read it —
    /// only the one-time load itself touches the database.
    private var conjugations: [String: String] = [:]

    private var topics: [(row: BibleTopicResult, tagStems: Set<String>)] = []

    private init() {
        openDatabase()
        // All one-time setup happens here, in `static let shared`'s
        // guaranteed-single-caller initializer — no locking needed for it.
        // `lock` below protects only the actual per-query sqlite3 calls in
        // `search`/`count`, which can happen concurrently from multiple callers.
        hasFTS = probeFTS()
        if hasFTS {
            conjugations = loadConjugations()
            topics = loadTopics()
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    var isAvailable: Bool { db != nil && hasFTS }

    // MARK: - Public API

    /// Stems of the query (surface + conjugation + NLTagger expansions, union
    /// over all surviving tokens), for `VerseSnippet` highlighting. Cheap;
    /// call once per query, not once per result row.
    func queryStems(_ query: String) -> Set<String> {
        let box = ConjugationBox(conjugations)
        let tokens = filteredTokens(SearchNormalizer.tokens(query))
        var stems = Set<String>()
        for token in tokens {
            stems.formUnion(SearchNormalizer.expand(token, conjugations: box, synonyms: [:]))
        }
        return stems
    }

    func search(query: String, testament: Testament?, limit: Int = 50, offset: Int = 0) -> [BibleSearchResult] {
        guard isAvailable, let db else { return [] }
        guard let match = matchExpression(for: query) else { return [] }

        let sql = """
        SELECT v.rowid, v.book_id, v.chapter, v.verse, v.synodal_text
        FROM verses_fts f
        JOIN verses v ON v.rowid = f.rowid
        JOIN books  b ON b.book_id = v.book_id
        WHERE verses_fts MATCH ?1
          AND (?2 IS NULL OR b.testament = ?2)
        ORDER BY bm25(verses_fts)
        LIMIT ?3 OFFSET ?4
        """

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (match as NSString).utf8String, -1, nil)
        if let raw = testamentRaw(testament) {
            sqlite3_bind_text(stmt, 2, (raw as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int(stmt, 3, Int32(limit))
        sqlite3_bind_int(stmt, 4, Int32(offset))

        var results: [BibleSearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            guard let bookIdPtr = sqlite3_column_text(stmt, 1) else { continue }
            let bookId = String(cString: bookIdPtr)
            let chapter = Int(sqlite3_column_int(stmt, 2))
            let verse = Int(sqlite3_column_int(stmt, 3))
            guard let textPtr = sqlite3_column_text(stmt, 4) else { continue }
            let text = String(cString: textPtr)

            let abbreviation = BibleSQLiteRepository.shared.bookById[bookId]?.abbreviation ?? bookId.uppercased()
            results.append(BibleSearchResult(
                id: rowid,
                bookId: bookId,
                bookAbbreviation: abbreviation,
                chapter: chapter,
                verse: verse,
                displayRef: "\(abbreviation) \(chapter):\(verse)",
                text: text
            ))
        }
        return results
    }

    func count(query: String, testament: Testament?) -> Int {
        guard isAvailable, let db else { return 0 }
        guard let match = matchExpression(for: query) else { return 0 }

        let sql = """
        SELECT count(*)
        FROM verses_fts f
        JOIN verses v ON v.rowid = f.rowid
        JOIN books  b ON b.book_id = v.book_id
        WHERE verses_fts MATCH ?1
          AND (?2 IS NULL OR b.testament = ?2)
        """

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (match as NSString).utf8String, -1, nil)
        if let raw = testamentRaw(testament) {
            sqlite3_bind_text(stmt, 2, (raw as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Curated "story I remember, not the words" matches (§4.6) — a plain
    /// in-memory scan over ~100 rows, same tradeoff as the prayers category
    /// tier (§3.4): cheaper and simpler than a second FTS table this small.
    func topics(matching query: String) -> [BibleTopicResult] {
        guard isAvailable else { return [] }
        let stems = queryStems(query)
        guard !stems.isEmpty else { return [] }

        var scored: [(row: BibleTopicResult, hits: Int)] = []
        scored.reserveCapacity(topics.count)
        for entry in topics {
            let hits: Int = entry.tagStems.intersection(stems).count
            if hits > 0 {
                scored.append((entry.row, hits))
            }
        }
        scored.sort { lhs, rhs in
            lhs.hits != rhs.hits ? lhs.hits > rhs.hits : lhs.row.title < rhs.row.title
        }
        return scored.prefix(5).map(\.row)
    }

    // MARK: - Match expression building (§4.3)

    /// Builds the `verses_fts MATCH` expression: an AND of per-token OR-groups
    /// (`SearchNormalizer.expand`), with two exceptions —
    ///  * a `"quoted phrase"` is passed through as one adjacency-preserving
    ///    FTS5 phrase over stems, never expanded (expansion would break
    ///    adjacency);
    ///  * a trailing `word*` performs an (undocumented-in-UI) prefix search
    ///    on that token's stem instead of the normal OR-expansion.
    private func matchExpression(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let box = ConjugationBox(conjugations)

        var groups: [String] = []
        var remainder = trimmed

        // Quoted phrases, e.g. "в начале было слово" -> one stem phrase.
        while let quoteRange = remainder.range(of: #""[^"]+""#, options: .regularExpression) {
            let phrase = String(remainder[quoteRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let stems = SearchNormalizer.tokens(phrase).map { SearchNormalizer.surfaceStem($0) }.filter { !$0.isEmpty }
            if !stems.isEmpty {
                let phraseTerm = stems.map { "\"\($0)\"" }.joined(separator: " ")
                groups.append("(\(phraseTerm))")
            }
            remainder.removeSubrange(quoteRange)
        }

        var rawTokens = SearchNormalizer.tokens(remainder)

        // Trailing prefix query: a `*` right after the last raw word.
        var prefixTerm: String?
        if remainder.trimmingCharacters(in: .whitespaces).hasSuffix("*"), let last = rawTokens.last {
            rawTokens.removeLast()
            let s = SearchNormalizer.surfaceStem(last)
            if !s.isEmpty { prefixTerm = "\(s)*" }
        }

        for token in filteredTokens(rawTokens) {
            let expansions = SearchNormalizer.expand(token, conjugations: box, synonyms: [:])
            guard !expansions.isEmpty else { continue }
            let quoted = expansions.map { "\"\($0)\"" }.joined(separator: " OR ")
            groups.append(expansions.count > 1 ? "(\(quoted))" : quoted)
        }

        if let prefixTerm {
            groups.append(prefixTerm)
        }

        guard !groups.isEmpty else { return nil }
        return groups.joined(separator: " AND ")
    }

    /// Domain stopwords (§1/§3.3, shared across prayers and Bible search) are
    /// dropped only if at least one non-stopword token survives.
    private func filteredTokens(_ tokens: [String]) -> [String] {
        let kept = tokens.filter { !SearchNormalizer.stopStems.contains(SearchNormalizer.surfaceStem($0)) }
        return kept.isEmpty ? tokens : kept
    }

    private func testamentRaw(_ testament: Testament?) -> String? {
        switch testament {
        case .old: return "old"
        case .new: return "new"
        case nil: return nil
        }
    }

    // MARK: - Setup

    private func openDatabase() {
        let candidates = [
            Bundle.main.url(forResource: "rus_synodal", withExtension: "sqlite", subdirectory: "Bible"),
            Bundle.main.url(forResource: "rus_synodal", withExtension: "sqlite"),
            Bundle.main.url(forResource: "rus_synodal", withExtension: "sqlite", subdirectory: "Resources/Bible")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            #if DEBUG
            print("[BibleSearchRepository] rus_synodal.sqlite not found in app bundle")
            #endif
            return
        }
        var connection: OpaquePointer?
        if sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = connection
        } else {
            if let connection { sqlite3_close(connection) }
        }
    }

    private func probeFTS() -> Bool {
        guard let db else { return false }
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM verses_fts LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        // A prepared statement is enough — a genuinely broken/missing FTS5
        // module would already have failed at prepare, not step.
        _ = sqlite3_step(stmt)
        return true
    }

    private func loadConjugations() -> [String: String] {
        guard let db else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT form, lemma FROM bible_conjugations", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let formPtr = sqlite3_column_text(stmt, 0), let lemmaPtr = sqlite3_column_text(stmt, 1) else { continue }
            result[String(cString: formPtr)] = String(cString: lemmaPtr)
        }
        return result
    }

    private func loadTopics() -> [(row: BibleTopicResult, tagStems: Set<String>)] {
        guard let db else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT id, title, tags_s, book_id, chapter, verse_start, display_ref FROM bible_topics"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var result: [(BibleTopicResult, Set<String>)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(stmt, 0))
            guard let titlePtr = sqlite3_column_text(stmt, 1),
                  let tagsPtr = sqlite3_column_text(stmt, 2),
                  let bookIdPtr = sqlite3_column_text(stmt, 3),
                  let refPtr = sqlite3_column_text(stmt, 6) else { continue }
            let title = String(cString: titlePtr)
            let tagsS = String(cString: tagsPtr)
            let bookId = String(cString: bookIdPtr)
            let chapter = Int(sqlite3_column_int(stmt, 4))
            let verseStart: Int? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
            let displayRef = String(cString: refPtr)

            let row = BibleTopicResult(
                id: id, title: title, displayRef: displayRef,
                bookId: bookId, chapter: chapter, verseStart: verseStart
            )
            result.append((row, Set(tagsS.split(separator: " ").map(String.init))))
        }
        return result
    }
}

/// `SearchNormalizer.expand` takes a `ConjugationLookup?` — this boxes the
/// repository's (read-only after `init`) `conjugations` dictionary so
/// `expand` has something to call without depending on the repository class
/// itself.
nonisolated private struct ConjugationBox: ConjugationLookup {
    let map: [String: String]
    init(_ map: [String: String]) { self.map = map }
    func lemma(for form: String) -> String? { map[form] }
}
