import Foundation

/// Thin adapter that lets Bible search recognise a query that is *itself* a
/// Bible reference ("Ин 3:16", "Быт 1", "1 Кор 13:4-8", "мф5:3") and jump
/// straight there, on top of running the normal text search underneath.
/// See search_design.md §4.2.
///
/// Reuses `ReadingReferenceParser` + `BookAliasMapper` unchanged — both are
/// designed for liturgical reading lists, not chapter jumps, so this adapter
/// covers the two gaps: a bare chapter number (`parse` requires a
/// chapter:verse body and returns `[]` for "Быт 1"), and no-space input like
/// "мф5:3" (the parser's own book/body splitter requires whitespace).
///
/// Not `nonisolated`, unlike `SearchNormalizer`/`RussianStemmer` — the two
/// types it reuses (`BookAliasMapper`, `ReadingReferenceParser`) are neither
/// of them marked `nonisolated`, so under this project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` they're implicitly
/// main-actor-isolated; a `nonisolated` caller synchronously calling them
/// would need `await` (or trip the Swift 6 strict-concurrency error this
/// project isn't opted into). `BibleReferenceQuery.parse` is only ever
/// called from `BibleSearchView`, already on the main actor.
enum BibleReferenceQuery {
    enum Result: Equatable {
        case chapter(bookId: String, chapter: Int)
        case verse(bookId: String, chapter: Int, verse: Int)
        case range([ReadingReference])

        static func == (lhs: Result, rhs: Result) -> Bool {
            switch (lhs, rhs) {
            case let (.chapter(lb, lc), .chapter(rb, rc)):
                return lb == rb && lc == rc
            case let (.verse(lb, lc, lv), .verse(rb, rc, rv)):
                return lb == rb && lc == rc && lv == rv
            case let (.range(l), .range(r)):
                return l == r
            default:
                return false
            }
        }
    }

    /// Returns non-nil only when the whole query parses as a Bible reference.
    static func parse(_ query: String) -> Result? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let (bookPart, bodyPart) = splitBookAndBody(trimmed), !bodyPart.isEmpty else { return nil }
        guard let bookId = BookAliasMapper.bookId(for: bookPart) else { return nil }

        // Bare chapter number ("Быт 1", "Пс 50", "1 Кор 13") — ReadingReferenceParser
        // is built for chapter:verse reading-list entries and returns [] here.
        if bodyPart.range(of: #"^\d+$"#, options: .regularExpression) != nil, let chapter = Int(bodyPart) {
            return .chapter(bookId: bookId, chapter: chapter)
        }

        // Reconstruct with a single normalised space so the parser's own
        // (private) book/body splitter — which requires whitespace — always
        // matches, even when the user typed none at all ("мф5:3").
        let normalized = "\(bookPart) \(bodyPart)"
        let references = ReadingReferenceParser().parse(raw: normalized, kind: .other)
        guard !references.isEmpty else { return nil }

        if references.count == 1, let only = references.first, only.verseStart == only.verseEnd {
            return .verse(bookId: only.bookId, chapter: only.chapter, verse: only.verseStart)
        }
        return .range(references)
    }

    // MARK: - Private

    /// Splits "<book><separator><digits…>" into (book, body). Tries the
    /// strict form first — book, required whitespace, digit-led body, the
    /// same shape `ReadingReferenceParser`'s own splitter uses — then falls
    /// back to a whitespace-optional form (leading non-digit run as the book)
    /// so "мф5:3" still parses.
    private static func splitBookAndBody(_ raw: String) -> (String, String)? {
        if let strict = capture(#"^(.+?)\s+([0-9].*)$"#, raw) {
            return strict
        }
        return capture(#"^([^\d]+?)([0-9].*)$"#, raw)
    }

    private static func capture(_ pattern: String, _ value: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges == 3,
              let r1 = Range(match.range(at: 1), in: value),
              let r2 = Range(match.range(at: 2), in: value)
        else { return nil }

        let book = String(value[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(value[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !book.isEmpty, !body.isEmpty else { return nil }
        return (book, body)
    }
}

#if DEBUG
extension BibleReferenceQuery {
    /// Static self-check for the worked examples in the search design spec.
    /// Call `BibleReferenceQuery.runSelfCheck()` (e.g. from a DEBUG launch
    /// hook) to print each query's parsed `Result` to the console.
    static func runSelfCheck() {
        let queries = ["Ин 3:16", "Быт 1", "1 Кор 13", "1Кор 13:4-8", "Пс 50", "мф5:3"]
        print("[BibleReferenceQuery] self-check:")
        for q in queries {
            print("  \(q.debugDescription) -> \(String(describing: parse(q)))")
        }
    }
}
#endif
