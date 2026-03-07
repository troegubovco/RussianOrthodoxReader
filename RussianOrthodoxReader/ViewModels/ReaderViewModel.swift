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
    @Published var hasPreviousChapter = false
    @Published var hasNextChapter = false

    private var chapterBook: BibleBook?
    private var loadedChapterRange: ClosedRange<Int>?
    private var isAppendingChapter = false
    private var isPrependingChapter = false

    func load(route: ReaderRoute) async {
        isLoading = true

        switch route {
        case let .chapter(bookId, chapter):
            await loadChapter(bookId: bookId, chapter: chapter)
        case let .references(title, references):
            await loadReferences(title: title, references: references)
        }

        isLoading = false
    }

    func loadNextChapterIfNeeded(after section: ReaderSection) {
        guard let book = chapterBook,
              let range = loadedChapterRange,
              let lastSection = sections.last,
              lastSection.id == section.id,
              !isAppendingChapter else {
            return
        }

        let nextChapter = range.upperBound + 1
        guard nextChapter <= book.chapterCount else {
            hasNextChapter = false
            return
        }

        isAppendingChapter = true
        let bookId = book.id
        let bookCount = book.chapterCount

        Task {
            let section = await Self.buildChapterSection(bookId: bookId, chapter: nextChapter)

            if let section {
                sections.append(section)
                loadedChapterRange = range.lowerBound...nextChapter
                refreshChapterBoundaries()
            } else {
                hasNextChapter = false
            }
            isAppendingChapter = false

            // Preload the chapter after that
            let preloadChapter = nextChapter + 1
            if preloadChapter <= bookCount {
                let repo = BibleSQLiteRepository.shared
                Task.detached(priority: .utility) {
                    _ = await repo.chapter(bookId: bookId, chapter: preloadChapter)
                }
            }
        }
    }

    func loadPreviousChapter() {
        guard let book = chapterBook,
              let range = loadedChapterRange,
              !isPrependingChapter else {
            return
        }

        let previousChapter = range.lowerBound - 1
        guard previousChapter >= 1 else {
            hasPreviousChapter = false
            return
        }

        isPrependingChapter = true
        let bookId = book.id

        Task {
            let section = await Self.buildChapterSection(bookId: bookId, chapter: previousChapter)

            if let section {
                sections.insert(section, at: 0)
                loadedChapterRange = previousChapter...range.upperBound
                refreshChapterBoundaries()
            } else {
                hasPreviousChapter = false
            }
            isPrependingChapter = false
        }
    }

    // MARK: - Private

    private func loadChapter(bookId: String, chapter: Int) async {
        guard let book = BibleDataProvider.book(id: bookId) else {
            title = "Чтение"
            sections = []
            errorMessage = "Книга не найдена"
            chapterBook = nil
            loadedChapterRange = nil
            hasPreviousChapter = false
            hasNextChapter = false
            return
        }

        let selectedChapter = min(max(1, chapter), max(1, book.chapterCount))

        let section = await Self.buildChapterSection(bookId: bookId, chapter: selectedChapter)

        guard let section else {
            title = "Чтение"
            sections = []
            errorMessage = "Глава не найдена в локальной базе"
            chapterBook = nil
            loadedChapterRange = nil
            hasPreviousChapter = false
            hasNextChapter = false
            return
        }

        chapterBook = book
        loadedChapterRange = selectedChapter...selectedChapter
        sections = [section]
        title = book.name
        errorMessage = nil
        refreshChapterBoundaries()

        // Preload adjacent chapters in background
        let bookCount = book.chapterCount
        let repo = BibleSQLiteRepository.shared
        Task.detached(priority: .utility) {
            if selectedChapter + 1 <= bookCount {
                _ = await repo.chapter(bookId: bookId, chapter: selectedChapter + 1)
            }
            if selectedChapter - 1 >= 1 {
                _ = await repo.chapter(bookId: bookId, chapter: selectedChapter - 1)
            }
        }
    }

    private func loadReferences(title: String, references: [ReadingReference]) async {
        self.title = title
        chapterBook = nil
        loadedChapterRange = nil
        hasPreviousChapter = false
        hasNextChapter = false

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

    private func refreshChapterBoundaries() {
        guard let book = chapterBook,
              let range = loadedChapterRange else {
            hasPreviousChapter = false
            hasNextChapter = false
            return
        }

        hasPreviousChapter = range.lowerBound > 1
        hasNextChapter = range.upperBound < book.chapterCount
    }
}
