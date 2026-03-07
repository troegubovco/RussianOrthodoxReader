import Foundation

// MARK: - Bible Structure

enum Testament: String, CaseIterable, Identifiable {
    case old = "Ветхий Завет"
    case new = "Новый Завет"

    var id: String { rawValue }
}

struct BibleBook: Identifiable, Hashable {
    let id: String
    let name: String
    let abbreviation: String
    let testament: Testament
    let chapterCount: Int
}

struct BibleChapter: Identifiable, Hashable {
    let id: String
    let bookId: String
    let bookName: String
    let chapter: Int
    let verses: [BibleVerse]
}

struct BibleVerse: Identifiable, Hashable {
    let id: Int
    let number: Int
    let synodal: String
}

enum ReaderRoute: Hashable, Identifiable {
    case chapter(bookId: String, chapter: Int)
    case references(title: String, references: [ReadingReference])

    var id: String {
        switch self {
        case let .chapter(bookId, chapter):
            return "chapter:\(bookId)-\(chapter)"
        case let .references(title, references):
            let token = references.map { $0.id }.joined(separator: "|")
            return "refs:\(title):\(token)"
        }
    }
}

// MARK: - Bible Data Provider

struct BibleDataProvider {
    private static let repository = BibleSQLiteRepository.shared

    static var books: [BibleBook] {
        repository.books
    }

    static func books(for testament: Testament) -> [BibleBook] {
        repository.books(for: testament)
    }

    static func chapter(bookId: String, chapter: Int) -> BibleChapter? {
        repository.chapter(bookId: bookId, chapter: chapter)
    }

    static func book(id: String) -> BibleBook? {
        repository.bookById[id]
    }

    static func chapterCount(bookId: String) -> Int {
        book(id: bookId)?.chapterCount ?? 0
    }

    static func verses(bookId: String, chapter: Int, range: ClosedRange<Int>?) -> [BibleVerse] {
        repository.verses(bookId: bookId, chapter: chapter, range: range)
    }

    static func hasChapter(bookId: String) -> Bool {
        repository.hasChapter(bookId: bookId)
    }

    static func firstAvailableChapter(bookId: String) -> String? {
        repository.firstAvailableChapter(bookId: bookId)
    }

    static func route(for chapterKey: String) -> ReaderRoute? {
        let parts = chapterKey.split(separator: "-")
        guard parts.count == 2, let chapter = Int(parts[1]) else { return nil }
        return .chapter(bookId: String(parts[0]), chapter: chapter)
    }

    static func chapterKey(bookId: String, chapter: Int) -> String {
        "\(bookId)-\(chapter)"
    }

}
