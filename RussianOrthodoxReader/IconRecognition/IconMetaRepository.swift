import Foundation
import SQLite3

// MARK: - Result models

struct IconSubjectInfo {
    let name: String
    let category: String            // saints | theotokos | christ | angels
    let feastDays: [String]         // parsed from feast_days_json, [] when absent
    let azbykaURL: String?
    let praviconURL: String?
}

struct IconLifeEntry {
    let life: String
    let source: String
}

struct IconHistoryEntry {
    let history: String
    let source: String
}

struct IconPrayerEntry: Identifiable {
    let id: Int                     // prayer_id — stable
    let kind: String                // use verbatim, NEVER .capitalized  (B2)
    let glas: String?               // TEXT, e.g. "глас 4"  (B1)
    let body: String                // Church Slavonic, deduped
    let translation: String?        // nil when absent
}

/// Read-only lookup over `icon_meta.sqlite` — жития, истории икон и молитвы,
/// keyed by `icon_id` (the id resolved by `IconRecognizer`/`PrototypeIndex`).
///
/// Follows the same sqlite3 C-API pattern as `BibleSQLiteRepository`. The
/// database is produced by `Tools/icon_ml/10_build_meta_db.py` and is not
/// bundled yet, so every method degrades to an empty result until it ships.
nonisolated final class IconMetaRepository: @unchecked Sendable {
    static let shared = IconMetaRepository()

    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        openDatabase()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    func subject(iconId: Int) -> IconSubjectInfo? {
        guard let db else { return nil }
        let sql = "SELECT name, category, feast_days_json, azbyka_url, pravicon_url FROM subjects WHERE icon_id = ? LIMIT 1"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(iconId))
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let namePtr = sqlite3_column_text(stmt, 0),
              let categoryPtr = sqlite3_column_text(stmt, 1) else { return nil }

        let feastDaysJSON = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let azbykaURL = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let praviconURL = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

        let feastDays: [String] = feastDaysJSON.flatMap { json in
            (try? JSONDecoder().decode([String].self, from: Data(json.utf8)))
        } ?? []

        return IconSubjectInfo(
            name: String(cString: namePtr),
            category: String(cString: categoryPtr),
            feastDays: feastDays,
            azbykaURL: azbykaURL,
            praviconURL: praviconURL
        )
    }

    /// Житие святого — shared across all icons of that saint. `icon_id` is a
    /// PRIMARY KEY on `lives`, so at most one row exists (B4).
    func life(iconId: Int) -> IconLifeEntry? {
        queryOne(sql: "SELECT life, source FROM lives WHERE icon_id = ? LIMIT 1", iconId: iconId) { stmt in
            guard let lifePtr = sqlite3_column_text(stmt, 0) else { return nil }
            let source = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "azbyka"
            return IconLifeEntry(life: String(cString: lifePtr), source: source)
        }
    }

    /// История иконы — for named icon types (Казанская, Владимирская, …).
    /// `icon_id` is a PRIMARY KEY on `histories`, so at most one row exists (B4).
    func history(iconId: Int) -> IconHistoryEntry? {
        queryOne(sql: "SELECT history, source FROM histories WHERE icon_id = ? LIMIT 1", iconId: iconId) { stmt in
            guard let historyPtr = sqlite3_column_text(stmt, 0) else { return nil }
            let source = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "azbyka"
            return IconHistoryEntry(history: String(cString: historyPtr), source: source)
        }
    }

    /// Тропарь, кондак, молитва, величание — ordered as scraped/curated.
    /// `translation` may not exist yet in older DB builds — prepare defensively,
    /// falling back to the 4-column select when the 5-column one fails.
    func prayers(iconId: Int) -> [IconPrayerEntry] {
        guard let db else { return [] }

        lock.lock()
        defer { lock.unlock() }

        let sqlWithTranslation = "SELECT prayer_id, kind, glas, body, translation FROM prayers WHERE icon_id = ? ORDER BY position, prayer_id"
        var stmt: OpaquePointer?
        var hasTranslation = true
        if sqlite3_prepare_v2(db, sqlWithTranslation, -1, &stmt, nil) != SQLITE_OK {
            hasTranslation = false
            let sqlWithoutTranslation = "SELECT prayer_id, kind, glas, body FROM prayers WHERE icon_id = ? ORDER BY position, prayer_id"
            guard sqlite3_prepare_v2(db, sqlWithoutTranslation, -1, &stmt, nil) == SQLITE_OK else { return [] }
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(iconId))

        var results: [IconPrayerEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kindPtr = sqlite3_column_text(stmt, 1),
                  let bodyPtr = sqlite3_column_text(stmt, 3) else { continue }
            let id = Int(sqlite3_column_int(stmt, 0))
            let glas = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 2))
            let translation: String?
            if hasTranslation {
                translation = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
            } else {
                translation = nil
            }
            results.append(IconPrayerEntry(
                id: id,
                kind: String(cString: kindPtr),
                glas: glas,
                body: String(cString: bodyPtr),
                translation: translation
            ))
        }
        return results
    }

    /// `SELECT w, h, jpeg FROM thumbs WHERE icon_id = ?` — fails soft (returns
    /// nil, no crash/log-spam) when the `thumbs` table doesn't exist yet.
    func thumbnailData(iconId: Int) -> (data: Data, width: Int, height: Int)? {
        guard let db else { return nil }
        let sql = "SELECT w, h, jpeg FROM thumbs WHERE icon_id = ? LIMIT 1"

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(iconId))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let width = Int(sqlite3_column_int(stmt, 0))
        let height = Int(sqlite3_column_int(stmt, 1))
        let byteCount = Int(sqlite3_column_bytes(stmt, 2))
        guard byteCount > 0, let blob = sqlite3_column_blob(stmt, 2) else { return nil }
        let data = Data(bytes: blob, count: byteCount)

        return (data: data, width: width, height: height)
    }

    // MARK: - Private

    private func openDatabase() {
        let candidates = [
            Bundle.main.url(forResource: "icon_meta", withExtension: "sqlite", subdirectory: "IconML"),
            Bundle.main.url(forResource: "icon_meta", withExtension: "sqlite")
        ]

        guard let url = candidates.compactMap({ $0 }).first else {
            #if DEBUG
            print("[IconMetaRepository] icon_meta.sqlite not found in app bundle")
            #endif
            return
        }

        var connection: OpaquePointer?
        if sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = connection
        } else {
            #if DEBUG
            if let connection, let cString = sqlite3_errmsg(connection) {
                print("[IconMetaRepository] sqlite open error: \(String(cString: cString))")
            }
            #endif
            if let connection {
                sqlite3_close(connection)
            }
        }
    }

    private func queryOne<T>(sql: String, iconId: Int, map: (OpaquePointer) -> T?) -> T? {
        guard let db else { return nil }

        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(iconId))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return map(stmt!)
    }
}
