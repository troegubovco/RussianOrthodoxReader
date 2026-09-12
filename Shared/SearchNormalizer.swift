import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// MARK: - Поиск: токенизация и нормализация запроса

/// Supplies a lemma for an inflected surface form, backed by a repository's own
/// `conjugations` table (`rus_dictionary.sqlite` for the Bible search index,
/// or an equivalent lookup for prayers). `SearchNormalizer` stays decoupled from
/// any concrete storage — callers inject whichever lookup they have open.
nonisolated protocol ConjugationLookup {
    /// Returns the lemma for `form`, or nil when `form` is not in the map.
    func lemma(for form: String) -> String?
}

/// Shared tokenizer / query-expansion pipeline. Runs identically at index build
/// time (via the Python port, `Tools/russian_stemmer.py` + the build scripts'
/// own tokenizer) and at query time (here). See search design notes, §1 and §2.4.
///
/// `nonisolated` because this is pure computation with no shared mutable state;
/// the project defaults actors to `@MainActor`, and both index-build-adjacent
/// callers and query-time callers off the main actor need to call these.
nonisolated enum SearchNormalizer {

    // MARK: Tokenisation

    /// Strip U+0301 (combining acute / stress mark), lowercase, ё→е, then split
    /// on any run of non-letter characters (digits included) — matching the
    /// Python build-time tokenizer's `[^\W\d_]+` regex over Unicode letters.
    static func tokens(_ text: String) -> [String] {
        let normalized = normalize(text)
        var result: [String] = []
        var current = ""
        current.reserveCapacity(16)
        for ch in normalized {
            if ch.isLetter {
                current.append(ch)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Lowercase, ё→е, strip U+0301. Does NOT split into tokens.
    private static func normalize(_ text: String) -> String {
        var scalars = text.unicodeScalars
        scalars.removeAll { $0.value == 0x0301 }
        return String(scalars).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    // MARK: Stemming

    /// Surface stem: `RussianStemmer.stem(token)`.
    static func surfaceStem(_ token: String) -> String {
        RussianStemmer.stem(token)
    }

    // MARK: Query-time expansion

    /// Query-time expansion for one token, de-duplicated, longest-stem-first:
    /// `surfaceStem(t) ∪ stem(conjugationLemma(t)) ∪ stem(nlLemma(t)) ∪ synonyms[surfaceStem(t)]`.
    ///
    /// - Parameters:
    ///   - token: a single already-tokenised query word (see `tokens(_:)`).
    ///   - conjugations: the repository's conjugation map, or nil to skip that source.
    ///   - synonyms: `stem -> [expansion stems]`, e.g. loaded from `search_synonyms`.
    static func expand(_ token: String,
                        conjugations: ConjugationLookup?,
                        synonyms: [String: [String]]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func add(_ candidate: String?) {
            guard let candidate, !candidate.isEmpty, !seen.contains(candidate) else { return }
            seen.insert(candidate)
            result.append(candidate)
        }

        let surface = surfaceStem(token)
        add(surface)

        if let lemma = conjugations?.lemma(for: token) {
            add(RussianStemmer.stem(lemma))
        }

        if let nl = nlLemma(token) {
            add(RussianStemmer.stem(nl))
        }

        for expansion in synonyms[surface] ?? [] {
            add(expansion)
        }

        // Stable sort, longest stem first — favors the more specific expansions
        // when a caller only takes a prefix of the OR-set.
        return result.enumerated()
            .sorted { a, b in
                a.element.count != b.element.count
                    ? a.element.count > b.element.count
                    : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: Stopwords

    /// Domain stopword stems (see §3.4): Russian function words plus the app's
    /// own domain noise words (`молитва`, `текст`, `читать`, `про`, …), pre-stemmed.
    /// Dropped from a query only if at least one non-stopword term survives.
    static let stopStems: Set<String> = [
        "а", "в", "для", "есл", "же", "за", "и", "из", "к", "как", "когд",
        "на", "не", "но", "о", "об", "он", "от", "перед", "по", "при", "про",
        "с", "у", "что", "чтоб", "я",
        // domain-specific
        "молитв", "текст", "чита",
    ]

    // MARK: NaturalLanguage best-effort booster (query-only, never the index)

    #if canImport(NaturalLanguage)
    private static let lemmaAvailable: Bool =
        NLTagger.availableTagSchemes(for: .word, language: .russian).contains(.lemma)
    #endif

    /// `NLTagger` `.lemma`, or nil when the scheme is unavailable on this
    /// platform/OS build (e.g. asset not present on watchOS). Query-only,
    /// best-effort: must never influence the shipped index.
    static func nlLemma(_ token: String) -> String? {
        #if canImport(NaturalLanguage)
        guard lemmaAvailable, !token.isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = token
        tagger.setLanguage(.russian, range: token.startIndex..<token.endIndex)
        let (tag, _) = tagger.tag(at: token.startIndex, unit: .word, scheme: .lemma)
        return tag?.rawValue
        #else
        return nil
        #endif
    }
}
