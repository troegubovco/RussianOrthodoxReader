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

extension ReaderRoute: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, bookId, chapter
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .chapter(bookId, chapter):
            try container.encode("chapter", forKey: .type)
            try container.encode(bookId, forKey: .bookId)
            try container.encode(chapter, forKey: .chapter)
        case .references:
            // References are date-specific liturgical readings — not persisted.
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "references are not persisted"))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "chapter":
            let bookId = try container.decode(String.self, forKey: .bookId)
            let chapter = try container.decode(Int.self, forKey: .chapter)
            self = .chapter(bookId: bookId, chapter: chapter)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown route type: \(type)"))
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
