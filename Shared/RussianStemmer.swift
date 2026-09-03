import Foundation

// MARK: - Русский стеммер (Snowball "Russian (Porter)")

/// Snowball "Russian (Porter)" stemmer, single pass.
/// MUST stay byte-for-byte equivalent to Tools/russian_stemmer.py — the bundled
/// FTS indexes are built with the Python version. See search design notes for
/// the full rationale (single pass, not iterated to a fixpoint; Snowball over an
/// ad-hoc stripper; never used as an index-time OS-dependent normaliser).
///
/// `nonisolated` because this is pure computation with no shared mutable state;
/// the project defaults actors to `@MainActor`, and both index-build-adjacent
/// callers and query-time callers off the main actor need to call `stem(_:)`.
nonisolated enum RussianStemmer {

    private static let vowels: Set<Character> = ["а", "е", "и", "о", "у", "ы", "э", "ю", "я", "ё"]

    // Ending lists are sorted longest-first ONCE here (not per call inside
    // `strip`), since `strip` is invoked ~4x per query token and once per
    // corpus token when reproducing the golden test.
    private static let perfectiveGerund1 = sortedLongestFirst(["вшись", "вши", "в"])
    private static let perfectiveGerund2 = sortedLongestFirst(["ившись", "ывшись", "ивши", "ывши", "ив", "ыв"])
    private static let adjective = sortedLongestFirst([
        "иями", "ями", "ими", "ыми", "ему", "ому", "его", "ого", "ее", "ие",
        "ые", "ое", "ей", "ий", "ый", "ой", "ем", "им", "ым", "ом", "их", "ых",
        "ую", "юю", "ая", "яя", "ою", "ею",
    ])
    private static let participle1 = sortedLongestFirst(["ющ", "вш", "ем", "нн", "щ"])
    private static let participle2 = sortedLongestFirst(["ующ", "ивш", "ывш"])
    private static let reflexive = sortedLongestFirst(["ся", "сь"])
    private static let verb1 = sortedLongestFirst([
        "ешь", "нно", "ете", "йте", "ла", "на", "ли", "ем", "ло", "но", "ет",
        "ют", "ны", "ть", "й", "л", "н",
    ])
    private static let verb2 = sortedLongestFirst([
        "ейте", "уйте", "ила", "ыла", "ена", "ите", "или", "ыли", "ило", "ыло",
        "ено", "ует", "уют", "ены", "ить", "ыть", "ишь", "ей", "уй", "ил", "ыл",
        "им", "ым", "ен", "ят", "ит", "ыт", "ую", "ю",
    ])
    private static let noun = sortedLongestFirst([
        "иями", "ями", "ами", "иях", "ях", "ах", "ией", "ев", "ов", "ие", "ье",
        "еи", "ии", "ей", "ой", "ий", "иям", "ям", "ием", "ем", "ам", "ом",
        "ию", "ью", "ия", "ья", "а", "е", "и", "й", "о", "у", "ы", "ь", "ю", "я",
    ])
    private static let superlative = sortedLongestFirst(["ейше", "ейш"])
    private static let derivational = sortedLongestFirst(["ость", "ост"])

    private static func sortedLongestFirst(_ endings: [String]) -> [[Character]] {
        endings.map(Array.init).sorted { $0.count > $1.count }
    }

    static func stem(_ word: String) -> String {
        var w = Array(word.lowercased().replacingOccurrences(of: "ё", with: "е"))
        let rv = rvIndex(w)
        let r2 = r2Index(w)

        // step 1
        if let s = strip(w, rv, perfectiveGerund1, precededBy: ["а", "я"])
            ?? strip(w, rv, perfectiveGerund2) {
            w = s
        } else {
            if let r = strip(w, rv, reflexive) { w = r }
            if let adj = strip(w, rv, adjective) {
                w = adj
                if let p = strip(w, rv, participle1, precededBy: ["а", "я"])
                    ?? strip(w, rv, participle2) { w = p }
            } else if let v = strip(w, rv, verb1, precededBy: ["а", "я"])
                ?? strip(w, rv, verb2) {
                w = v
            } else if let n = strip(w, rv, noun) {
                w = n
            }
        }
        // step 2
        if w.last == "и", w.count - 1 >= rv { w.removeLast() }
        // step 3
        if let d = strip(w, r2, derivational) { w = d }
        // step 4
        if w.count >= 2, w[w.count - 2] == "н", w[w.count - 1] == "н" {
            w.removeLast()
        } else if let s = strip(w, rv, superlative) {
            w = s
            if w.count >= 2, w[w.count - 2] == "н", w[w.count - 1] == "н" { w.removeLast() }
        } else if w.last == "ь" {
            w.removeLast()
        }
        return String(w)
    }

    // MARK: - private

    private static func rvIndex(_ w: [Character]) -> Int {
        for (i, ch) in w.enumerated() where vowels.contains(ch) { return i + 1 }
        return w.count
    }

    private static func r2Index(_ w: [Character]) -> Int {
        let n = w.count
        var i = 0
        while i < n - 1 && !(vowels.contains(w[i]) && !vowels.contains(w[i + 1])) { i += 1 }
        let r1 = i + 2
        i = min(r1, max(0, n - 1))
        while i < n - 1 && !(vowels.contains(w[i]) && !vowels.contains(w[i + 1])) { i += 1 }
        return i + 2
    }

    /// Longest ending from `endings` (already sorted longest-first), whose start
    /// index is >= `start`. `precededBy` requires that character immediately
    /// before the ending; it is KEPT.
    private static func strip(_ w: [Character], _ start: Int, _ endings: [[Character]],
                               precededBy: Set<Character>? = nil) -> [Character]? {
        for e in endings {
            guard w.count >= e.count, w.count - e.count >= start else { continue }
            guard Array(w.suffix(e.count)) == e else { continue }
            let base = Array(w.prefix(w.count - e.count))
            if let precededBy {
                guard let last = base.last, precededBy.contains(last) else { continue }
                return base                        // the а/я stays
            }
            return base
        }
        return nil
    }
}
