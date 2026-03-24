import Combine
import Foundation

struct ReaderSection: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let verses: [BibleVerse]
    let bookId: String?
    let chapter: Int?
}

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var title: String = ""
    @Published var sections: [ReaderSection] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Set after loading to tell the view which section to scroll to.
    @Published var scrollToSectionID: String?

    private var chapterBook: BibleBook?
    /// Task handle for the background full-book load, so it can be cancelled
    /// if the user navigates away before it finishes.
    private var bookLoadTask: Task<Void, Never>?

    func load(route: ReaderRoute) async {
        // Cancel any in-flight background book load
        bookLoadTask?.cancel()
        bookLoadTask = nil

        isLoading = true

        switch route {
        case let .chapter(bookId, chapter):
            await loadBook(bookId: bookId, chapter: chapter)
        case let .references(title, references):
            await loadReferences(title: title, references: references)
        }

        isLoading = false
    }

    // MARK: - Private

    /// Two-phase book loading:
    /// Phase 1: Load the target chapter immediately so the user sees content.
    /// Phase 2: Load all remaining chapters in the background and replace the sections array.
    private func loadBook(bookId: String, chapter: Int) async {
        guard let book = BibleDataProvider.book(id: bookId) else {
            title = "Чтение"
            sections = []
            errorMessage = "Книга не найдена"
            chapterBook = nil
            return
        }

        let selectedChapter = min(max(1, chapter), max(1, book.chapterCount))

        // Phase 1: Load target chapter for instant display
        let targetSection = await Self.buildChapterSection(bookId: bookId, chapter: selectedChapter)

        guard let targetSection else {
            title = "Чтение"
            sections = []
            errorMessage = "Глава не найдена в локальной базе"
            chapterBook = nil
            return
        }

        chapterBook = book
        sections = [targetSection]
        title = book.name
        errorMessage = nil
        scrollToSectionID = targetSection.id

        // Phase 2: Load all chapters in the background
        let chapterCount = book.chapterCount
        let targetID = targetSection.id

        bookLoadTask = Task {
            var allSections: [ReaderSection] = []
            allSections.reserveCapacity(chapterCount)

            for ch in 1...chapterCount {
                guard !Task.isCancelled else { return }

                if ch == selectedChapter {
                    // Reuse the already-built target section
                    allSections.append(targetSection)
                } else if let section = await Self.buildChapterSection(bookId: bookId, chapter: ch) {
                    allSections.append(section)
                }
            }

            guard !Task.isCancelled else { return }

            // Replace sections with the full book.
            // First nil out scrollToSectionID, then set it after a tick,
            // so .onChange fires even though the target ID is the same value.
            scrollToSectionID = nil
            sections = allSections
            // Allow SwiftUI to process the sections change, then scroll.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            scrollToSectionID = targetID
        }
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
                let verses = await repo.verses(bookId: reference.bookId, chapter: reference.chapter, range: safeStart...safeEnd)

                let fallback = verses.isEmpty
                    ? [BibleVerse(id: reference.verseStart, number: reference.verseStart, synodal: "Текст этого отрывка не найден в локальной базе")]
                    : verses

                let label = await repo.bookById[reference.bookId]?.abbreviation ?? reference.bookId.uppercased()
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

    private static func buildChapterSection(bookId: String, chapter: Int) async -> ReaderSection? {
        let repo = BibleSQLiteRepository.shared
        return await Task.detached(priority: .userInitiated) {
            guard let chapterData = await repo.chapter(bookId: bookId, chapter: chapter) else {
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
        }.value
    }
}
