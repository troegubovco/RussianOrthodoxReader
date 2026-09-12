import Combine
import Foundation

struct ReaderSection: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let verses: [BibleVerse]
    let bookId: String?
    let chapter: Int?
    /// Set on the last psalm-range of a kathisma «Слава» — `ReaderView`'s
    /// flattened row list renders a `.divider(text:)` row right after this
    /// section's verses. `nil` everywhere else (chapters, `.references`).
    var trailingDivider: String? = nil
}

struct ReaderScrollRequest: Equatable {
    let id: String
    let animated: Bool
    let token = UUID()
}

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var title: String = ""
    @Published var sections: [ReaderSection] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Set after loading to tell the view which section to scroll to.
    @Published var scrollRequest: ReaderScrollRequest?

    private var chapterBook: BibleBook?
    private var loadTask: Task<Void, Never>?

    /// - Parameter targetVerse: when set (and the route is `.chapter`), the
    ///   view is asked to scroll to that verse instead of the top of the
    ///   chapter — used by Bible search result taps and the `SINODAL_OPEN_VERSE`
    ///   DEBUG launch hook. See search_design.md §4.5.
    /// - Parameter targetSlava: when set (and the route is `.kathisma`), the
    ///   view scrolls to that «Слава» (1...3) instead of the top of the
    ///   kathisma — used by `PsalterSheet`'s «Слава» sub-rows. See
    ///   akathist_psalter_design.md §6.2.
    func load(route: ReaderRoute, targetVerse: Int? = nil, targetSlava: Int? = nil) {
        loadTask?.cancel()
        loadTask = Task {
            scrollRequest = nil
            isLoading = true

            switch route {
            case let .chapter(bookId, chapter):
                await loadBook(bookId: bookId, chapter: chapter, targetVerse: targetVerse)
            case let .references(title, references):
                await loadReferences(title: title, references: references)
            case let .kathisma(number):
                await loadKathisma(number: number, targetSlava: targetSlava)
            }

            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }

    // MARK: - Private

    /// Load all chapters of the book at once, then scroll to the target chapter
    /// (or, when `targetVerse` is set, to that specific verse within it).
    private func loadBook(bookId: String, chapter: Int, targetVerse: Int? = nil) async {
        guard let book = BibleDataProvider.book(id: bookId) else {
            title = "Чтение"
            sections = []
            errorMessage = "Книга не найдена"
            chapterBook = nil
            return
        }

        let selectedChapter = min(max(1, chapter), max(1, book.chapterCount))
        let chapterCount = book.chapterCount

        let allSections: [ReaderSection] = await Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: (Int, ReaderSection?).self) { group in
                for ch in 1...chapterCount {
                    group.addTask {
                        (ch, Self.buildChapterSection(bookId: bookId, chapter: ch))
                    }
                }
                var indexed: [(Int, ReaderSection)] = []
                indexed.reserveCapacity(chapterCount)
                for await (ch, section) in group {
                    if let section { indexed.append((ch, section)) }
                }
                return indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
            }
        }.value

        guard !allSections.isEmpty else {
            title = "Чтение"
            sections = []
            errorMessage = "Глава не найдена в локальной базе"
            chapterBook = nil
            return
        }

        chapterBook = book
        sections = allSections
        title = book.name
        errorMessage = nil
        // Flip `isLoading` off *before* publishing `scrollRequest`: the view
        // swaps its ProgressView for the actual (LazyVStack of) verse rows
        // only once `isLoading` is false, and `ScrollPosition.scrollTo(id:)`
        // silently no-ops if the target id isn't in the tree yet. Publishing
        // both in the same run-loop turn, in this order, keeps them in the
        // same SwiftUI update so the row exists by the time scrollTo runs —
        // this only matters now that a scroll target can be a specific verse
        // deep in the chapter, not just the (already-default) top of a fresh
        // ScrollView. See search_design.md §4.5.
        isLoading = false
        let sectionID = "\(bookId)-\(selectedChapter)"
        let scrollID = targetVerse.map { "\(sectionID)#\($0)" } ?? sectionID
        scrollRequest = ReaderScrollRequest(id: scrollID, animated: false)
    }

    private func loadReferences(title: String, references: [ReadingReference]) async {
        self.title = title
        chapterBook = nil

        let sortedRefs = references.sorted(by: { $0.ordinal < $1.ordinal })

        let repo = BibleSQLiteRepository.shared
        let built: [ReaderSection] = await Task.detached(priority: .userInitiated) {
            var result: [ReaderSection] = []

            for reference in sortedRefs {
                // Defensive: ensure valid ClosedRange even if data is malformed
                let safeStart = max(1, min(reference.verseStart, reference.verseEnd))
                let safeEnd = max(safeStart, max(reference.verseStart, reference.verseEnd))
                let verses = repo.verses(bookId: reference.bookId, chapter: reference.chapter, range: safeStart...safeEnd)

                let fallback = verses.isEmpty
                    ? [BibleVerse(id: reference.verseStart, number: reference.verseStart, synodal: "Текст этого отрывка не найден в локальной базе")]
                    : verses

                let label = repo.bookById[reference.bookId]?.abbreviation ?? reference.bookId.uppercased()
                let subtitle: String
                if reference.verseStart == reference.verseEnd {
                    subtitle = "\(label) \(reference.chapter):\(reference.verseStart)"
                } else {
                    subtitle = "\(label) \(reference.chapter):\(reference.verseStart)-\(reference.verseEnd)"
                }

                result.append(
                    ReaderSection(
                        id: reference.id,
                        title: reference.displayRef,
                        subtitle: subtitle,
                        verses: fallback,
                        bookId: reference.bookId,
                        chapter: reference.chapter
                    )
                )
            }

            return result
        }.value

        sections = built
        errorMessage = built.isEmpty ? "Нет доступных отрывков для отображения" : nil
    }

    /// One `ReaderSection` per `KathismaTable.PsalmRange` in the kathisma
    /// (three «Славы», plus Kathisma 20's Psalm 151 appendix), each followed
    /// by a «Слава» divider row where the range is the last one of its
    /// «Слава». See akathist_psalter_design.md §6.2/§6.3.
    private func loadKathisma(number: Int, targetSlava: Int? = nil) async {
        chapterBook = nil

        guard let kathisma = KathismaTable.all.first(where: { $0.number == number }) else {
            title = "Кафизма"
            sections = []
            errorMessage = "Кафизма не найдена"
            return
        }

        let repo = BibleSQLiteRepository.shared
        let built: [ReaderSection] = await Task.detached(priority: .userInitiated) {
            var result: [ReaderSection] = []
            for slava in kathisma.slavas {
                for (rangeIndex, range) in slava.ranges.enumerated() {
                    let isLastOfSlava = rangeIndex == slava.ranges.count - 1
                    result.append(Self.buildPsalmSection(range, repo: repo, trailingDivider: isLastOfSlava ? "Слава" : nil))
                }
            }
            for range in kathisma.appendix {
                result.append(Self.buildPsalmSection(range, repo: repo, trailingDivider: nil))
            }
            return result
        }.value

        title = "Кафизма \(number)"
        sections = built
        errorMessage = built.isEmpty ? "Текст кафизмы не найден в локальной базе" : nil
        // See the comment in `loadBook` — flip `isLoading` off before
        // publishing `scrollRequest`, in the same run-loop turn, so the
        // target row already exists in the tree when `scrollTo` runs.
        isLoading = false

        let targetRange: KathismaTable.PsalmRange? = targetSlava.flatMap { slavaNumber in
            guard kathisma.slavas.indices.contains(slavaNumber - 1) else { return nil }
            return kathisma.slavas[slavaNumber - 1].ranges.first
        }
        if let scrollRange = targetRange ?? kathisma.slavas.first?.ranges.first {
            scrollRequest = ReaderScrollRequest(id: Self.kathismaSectionID(for: scrollRange), animated: false)
        }
    }

    nonisolated private static func buildPsalmSection(
        _ range: KathismaTable.PsalmRange,
        repo: BibleSQLiteRepository,
        trailingDivider: String?
    ) -> ReaderSection {
        let verses: [BibleVerse]
        let subtitle: String
        if let verseRange = range.verses {
            verses = repo.verses(bookId: "psa", chapter: range.psalm, range: verseRange)
            subtitle = "Пс \(range.psalm):\(verseRange.lowerBound)–\(verseRange.upperBound)"
        } else {
            verses = repo.verses(bookId: "psa", chapter: range.psalm, range: nil)
            subtitle = "Пс \(range.psalm)"
        }
        return ReaderSection(
            id: kathismaSectionID(for: range),
            title: "Псалом \(range.psalm)",
            subtitle: subtitle,
            verses: verses,
            bookId: "psa",
            chapter: range.psalm,
            trailingDivider: trailingDivider
        )
    }

    /// Shared by the section builder above and the scroll-target lookup in
    /// `loadKathisma` so the two ids never drift apart: for a whole psalm
    /// this is "psa-N" — the same id a plain `.chapter` route for that psalm
    /// would use. Kathisma 17's three verse-split «Славы» all cover Psalm
    /// 118, so the verse start is appended to keep those three ids distinct.
    nonisolated private static func kathismaSectionID(for range: KathismaTable.PsalmRange) -> String {
        if let verses = range.verses {
            return "psa-\(range.psalm)-\(verses.lowerBound)"
        }
        return "psa-\(range.psalm)"
    }

    nonisolated private static func buildChapterSection(bookId: String, chapter: Int) -> ReaderSection? {
        let repo = BibleSQLiteRepository.shared
        guard let chapterData = repo.chapter(bookId: bookId, chapter: chapter) else {
            return nil
        }
        return ReaderSection(
            id: chapterData.id,
            title: chapterData.bookName,
            subtitle: "Глава \(chapterData.chapter)",
            verses: chapterData.verses,
            bookId: chapterData.bookId,
            chapter: chapterData.chapter
        )
    }
}
