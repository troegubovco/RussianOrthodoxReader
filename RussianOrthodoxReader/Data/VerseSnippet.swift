import SwiftUI

/// Builds a highlighted, windowed snippet of verse text for a Bible search
/// result row. See search_design.md §4.4.
///
/// Snippets are built here, in Swift, from the verse's *original* text —
/// `verses_fts` is a contentless FTS5 table over stems, so `snippet()`/
/// `highlight()` are both unavailable (and would highlight/return stems, not
/// readable text, even if they worked). Building it ourselves also gives
/// correct highlighting on the *surface* form (e.g. "возлюби" highlighted for
/// the query "любовь"), which `highlight()` over a stems column could never do.
///
/// Not `nonisolated`, unlike `SearchNormalizer`/`RussianStemmer`: it reads
/// `OrthodoxColors.fallback`, and this project's `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor` makes that (like the rest of DesignSystem.swift) implicitly
/// main-actor-isolated. That's fine — building ~50 short snippets is
/// microseconds of work, done inline while rendering the results list on the
/// main actor, exactly where `BibleSearchView` already is.
enum VerseSnippet {
    private static let theme = OrthodoxColors.fallback

    /// A ±`window`-character slice of `text` centred on the first token whose
    /// stem is in `queryStems`, snapped outward to word boundaries, with every
    /// matching token marked (accent color + bold). Falls back to the start of
    /// the text when no token in it matches — the hit may have come purely via
    /// the conjugation-map or NLTagger query expansion, not a literal stem.
    static func make(text: String, queryStems: Set<String>, window: Int = 60) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(text) }

        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return AttributedString(text) }

        let anchorIndex = queryStems.isEmpty
            ? 0
            : (tokens.firstIndex(where: { queryStems.contains($0.stem) }) ?? 0)
        let anchor = tokens[anchorIndex]

        let charWindow = max(window, 10)
        let roughLower = text.index(anchor.range.lowerBound, offsetBy: -charWindow, limitedBy: text.startIndex)
            ?? text.startIndex
        let roughUpper = text.index(anchor.range.upperBound, offsetBy: charWindow, limitedBy: text.endIndex)
            ?? text.endIndex

        let startTokenIdx = tokens.firstIndex(where: { $0.range.upperBound > roughLower }) ?? 0
        let endTokenIdx = tokens.lastIndex(where: { $0.range.lowerBound < roughUpper }) ?? tokens.count - 1

        let displayStart = tokens[startTokenIdx].range.lowerBound
        let displayEnd = tokens[endTokenIdx].range.upperBound

        var result = AttributedString(displayStart > text.startIndex ? "…" : "")
        var cursor = displayStart

        for idx in startTokenIdx...endTokenIdx {
            let token = tokens[idx]
            if cursor < token.range.lowerBound {
                result += AttributedString(String(text[cursor..<token.range.lowerBound]))
            }
            var piece = AttributedString(String(text[token.range]))
            if queryStems.contains(token.stem) {
                piece.foregroundColor = theme.accent
                // Bold via presentation intent rather than an absolute `.font`,
                // so the run still inherits whatever size/family the row's
                // `.font()` modifier sets (AppFont / userFontSize) instead of
                // hardcoding a point size this pure-text function doesn't know.
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result += piece
            cursor = token.range.upperBound
        }

        if cursor < displayEnd {
            result += AttributedString(String(text[cursor..<displayEnd]))
        }
        if displayEnd < text.endIndex {
            result += AttributedString("…")
        }
        return result
    }

    // MARK: - Private

    private struct Token {
        let range: Range<String.Index>
        let stem: String
    }

    /// Same letter-run splitting as `SearchNormalizer.tokens(_:)`, but keeps
    /// each token's range into the *original* string instead of collecting
    /// normalised copies — snippet highlighting needs to slice the surface text.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isLetter {
                if start == nil { start = i }
            } else if let s = start {
                let range = s..<i
                tokens.append(Token(range: range, stem: SearchNormalizer.surfaceStem(String(text[range]))))
                start = nil
            }
            i = text.index(after: i)
        }
        if let s = start {
            let range = s..<text.endIndex
            tokens.append(Token(range: range, stem: SearchNormalizer.surfaceStem(String(text[range]))))
        }
        return tokens
    }
}
