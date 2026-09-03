import Foundation

/// Static table of the traditional 20-kathisma / 60-«Слава» division of the
/// Psalter, transcribed from the Church-Slavonic «Псалтирь по кафизмам» page
/// on azbyka.ru (akathist_psalter_design.md §1.3). Psalm numbers follow the
/// Septuagint/Church-Slavonic numbering — the same numbering the bundled
/// Synodal `bible.sqlite` uses for `psa` chapters (Пс 9 has 39 verses, i.e.
/// 9+10 merged; Пс 118 has 176 verses).
///
/// Package D owns this table and its two consumers, `ReaderViewModel.loadKathisma`
/// and `PsalterSheet`; nothing else in the app should hardcode kathisma ranges.
nonisolated enum KathismaTable {
    /// A contiguous slice of one psalm. `verses == nil` means the whole psalm —
    /// true for every range in the table except Kathisma 17's three «Славы»,
    /// which are the only ones that divide a single psalm (118) by verse
    /// rather than by whole psalms.
    struct PsalmRange: Hashable {
        let psalm: Int
        let verses: ClosedRange<Int>?
    }

    /// One of the three «Славы» a kathisma is read in. `ranges` is one or more
    /// whole psalms, or (Kathisma 17 only) a single verse-range of Psalm 118.
    struct Slava: Hashable {
        let ranges: [PsalmRange]

        /// "Пс 1–3" / "Пс 9" / "Пс 118:1–72".
        var label: String {
            if ranges.count == 1, let only = ranges.first {
                if let verses = only.verses {
                    return "Пс \(only.psalm):\(verses.lowerBound)–\(verses.upperBound)"
                }
                return "Пс \(only.psalm)"
            }
            guard let first = ranges.first, let last = ranges.last else { return "" }
            return "Пс \(first.psalm)–\(last.psalm)"
        }
    }

    struct Kathisma: Hashable {
        let number: Int
        /// The kathisma's display psalm range — for Kathisma 20 this includes
        /// Psalm 151 even though it's read after (and isn't counted among)
        /// the third «Слава», matching how azbyka labels the kathisma itself
        /// ("Кафисма 20-я (псалмы 143–151)").
        let psalms: ClosedRange<Int>
        /// Always exactly 3.
        let slavas: [Slava]
        /// Only Kathisma 20 has one: Psalm 151, "вне числа 150 псалмов",
        /// read after the third «Слава» as its own appendix section.
        let appendix: [PsalmRange]

        /// "Псалмы 1–8" / "Псалом 118" / "Псалмы 143–151".
        var psalmsLabel: String {
            psalms.lowerBound == psalms.upperBound
                ? "Псалом \(psalms.lowerBound)"
                : "Псалмы \(psalms.lowerBound)–\(psalms.upperBound)"
        }
    }

    static func kathisma(containing psalm: Int) -> Kathisma? {
        all.first { $0.psalms.contains(psalm) || $0.appendix.contains { $0.psalm == psalm } }
    }

    /// One `Slava` spanning a contiguous run of whole psalms.
    private static func wholePsalms(_ range: ClosedRange<Int>) -> Slava {
        Slava(ranges: range.map { PsalmRange(psalm: $0, verses: nil) })
    }

    /// One `Slava` spanning a single verse-range of one psalm (Kathisma 17 only).
    private static func verses(of psalm: Int, _ range: ClosedRange<Int>) -> Slava {
        Slava(ranges: [PsalmRange(psalm: psalm, verses: range)])
    }

    static let all: [Kathisma] = [
        Kathisma(number: 1, psalms: 1...8,
                 slavas: [wholePsalms(1...3), wholePsalms(4...6), wholePsalms(7...8)],
                 appendix: []),
        Kathisma(number: 2, psalms: 9...16,
                 slavas: [wholePsalms(9...9), wholePsalms(10...13), wholePsalms(14...16)],
                 appendix: []),
        Kathisma(number: 3, psalms: 17...23,
                 slavas: [wholePsalms(17...17), wholePsalms(18...20), wholePsalms(21...23)],
                 appendix: []),
        Kathisma(number: 4, psalms: 24...31,
                 slavas: [wholePsalms(24...26), wholePsalms(27...29), wholePsalms(30...31)],
                 appendix: []),
        Kathisma(number: 5, psalms: 32...36,
                 slavas: [wholePsalms(32...33), wholePsalms(34...35), wholePsalms(36...36)],
                 appendix: []),
        Kathisma(number: 6, psalms: 37...45,
                 slavas: [wholePsalms(37...39), wholePsalms(40...42), wholePsalms(43...45)],
                 appendix: []),
        Kathisma(number: 7, psalms: 46...54,
                 slavas: [wholePsalms(46...48), wholePsalms(49...50), wholePsalms(51...54)],
                 appendix: []),
        Kathisma(number: 8, psalms: 55...63,
                 slavas: [wholePsalms(55...57), wholePsalms(58...60), wholePsalms(61...63)],
                 appendix: []),
        Kathisma(number: 9, psalms: 64...69,
                 slavas: [wholePsalms(64...65), wholePsalms(66...67), wholePsalms(68...69)],
                 appendix: []),
        Kathisma(number: 10, psalms: 70...76,
                 slavas: [wholePsalms(70...71), wholePsalms(72...73), wholePsalms(74...76)],
                 appendix: []),
        Kathisma(number: 11, psalms: 77...84,
                 slavas: [wholePsalms(77...77), wholePsalms(78...80), wholePsalms(81...84)],
                 appendix: []),
        Kathisma(number: 12, psalms: 85...90,
                 slavas: [wholePsalms(85...87), wholePsalms(88...88), wholePsalms(89...90)],
                 appendix: []),
        Kathisma(number: 13, psalms: 91...100,
                 slavas: [wholePsalms(91...93), wholePsalms(94...96), wholePsalms(97...100)],
                 appendix: []),
        Kathisma(number: 14, psalms: 101...104,
                 slavas: [wholePsalms(101...102), wholePsalms(103...103), wholePsalms(104...104)],
                 appendix: []),
        Kathisma(number: 15, psalms: 105...108,
                 slavas: [wholePsalms(105...105), wholePsalms(106...106), wholePsalms(107...108)],
                 appendix: []),
        Kathisma(number: 16, psalms: 109...117,
                 slavas: [wholePsalms(109...111), wholePsalms(112...114), wholePsalms(115...117)],
                 appendix: []),
        // K17 — the only kathisma whose three «Славы» divide a single psalm
        // (118) by verse rather than by whole psalms.
        Kathisma(number: 17, psalms: 118...118,
                 slavas: [verses(of: 118, 1...72), verses(of: 118, 73...131), verses(of: 118, 132...176)],
                 appendix: []),
        Kathisma(number: 18, psalms: 119...133,
                 slavas: [wholePsalms(119...123), wholePsalms(124...128), wholePsalms(129...133)],
                 appendix: []),
        Kathisma(number: 19, psalms: 134...142,
                 slavas: [wholePsalms(134...136), wholePsalms(137...139), wholePsalms(140...142)],
                 appendix: []),
        // K20 — the only kathisma with an appendix: Psalm 151, read after the
        // third «Слава», outside the numbered 150 psalms.
        Kathisma(number: 20, psalms: 143...151,
                 slavas: [wholePsalms(143...144), wholePsalms(145...147), wholePsalms(148...150)],
                 appendix: [PsalmRange(psalm: 151, verses: nil)]),
    ]
}
