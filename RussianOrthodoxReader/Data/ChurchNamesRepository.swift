import Foundation
import SQLite3

/// Результат поиска церковного имени по светской/уменьшительной форме.
struct ChurchNameMatch: Identifiable, Hashable {
    let id: Int
    let canonical: String   // «Георгий»
    let gender: PersonGender
    let genitive: String    // «Георгия»
    let accusative: String  // «Георгия»
    let dative: String?     // «Георгию»
    let isPrimary: Bool
    let note: String?
}

/// Доступ к встроенной базе соответствий имён (church_names.sqlite).
final class ChurchNamesRepository {
    static let shared = ChurchNamesRepository()

    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        openDatabase()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Соответствия для введённого имени (без учёта регистра, ё → е).
    /// Основные варианты — первыми.
    func matches(for input: String) -> [ChurchNameMatch] {
        guard let db else { return [] }
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
        guard !normalized.isEmpty else { return [] }

        let sql = """
        SELECT id, canonical, gender, gen, acc, dat, is_primary, note
        FROM names
        WHERE input_form = ?
        ORDER BY is_primary DESC, id
        """
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)

        var result: [ChurchNameMatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let canonicalPtr = sqlite3_column_text(stmt, 1),
                let genderPtr = sqlite3_column_text(stmt, 2),
                let genPtr = sqlite3_column_text(stmt, 3),
                let accPtr = sqlite3_column_text(stmt, 4)
            else { continue }
            result.append(ChurchNameMatch(
                id: Int(sqlite3_column_int(stmt, 0)),
                canonical: String(cString: canonicalPtr),
                gender: PersonGender(rawValue: String(cString: genderPtr)) ?? .male,
                genitive: String(cString: genPtr),
                accusative: String(cString: accPtr),
                dative: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                isPrimary: sqlite3_column_int(stmt, 6) != 0,
                note: sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            ))
        }
        return result
    }

    private func openDatabase() {
        let candidates = [
            Bundle.main.url(forResource: "church_names", withExtension: "sqlite"),
            Bundle.main.url(forResource: "church_names", withExtension: "sqlite",
                            subdirectory: "Resources"),
            Bundle.main.url(forResource: "church_names", withExtension: "sqlite",
                            subdirectory: "Bible")
        ]
        guard let url = candidates.compactMap({ $0 }).first else { return }
        var connection: OpaquePointer?
        if sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = connection
        } else {
            if let connection { sqlite3_close(connection) }
        }
    }
}
