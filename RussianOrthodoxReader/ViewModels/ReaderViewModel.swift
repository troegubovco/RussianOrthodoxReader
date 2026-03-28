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

    func load(route: ReaderRoute) {
        loadTask?.cancel()
        loadTask = Task {
            scrollRequest = nil
            isLoading = true

            switch route {
            case let .chapter(bookId, chapter):
                await loadBook(bookId: bookId, chapter: chapter)
            case let .references(title, references):
                await loadReferences(title: title, references: references)
            }

            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }

    // MARK: - Private

    /// Load all chapters of the book at once, then scroll to the target chapter.
    private func loadBook(bookId: String, chapter: Int) async {
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
        scrollRequest = ReaderScrollRequest(id: "\(bookId)-\(selectedChapter)", animated: false)
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
