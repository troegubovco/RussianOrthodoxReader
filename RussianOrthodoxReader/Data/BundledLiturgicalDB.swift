import Foundation
import SQLite3

/// Reads liturgical data from the bundled `liturgical_calendar.sqlite` database.
///
/// The database contains two tables derived from a complete 2025 scrape of Azbyka.ru:
///   - `fixed_saints(month, day, saints_json)` — saints keyed by Gregorian month-day
///   - `moveable_cycle(pascha_offset, apostol_display, gospel_display, ...)` — readings keyed by days from Pascha
///
/// For any year, we compute the Pascha offset for the target date and look up the corresponding readings.
/// Saints are fixed to the Gregorian calendar and looked up by month-day.
final class BundledLiturgicalDB {
    static let shared = BundledLiturgicalDB()

    private var db: OpaquePointer?

    private init() {
        guard let path = Bundle.main.path(forResource: "liturgical_calendar", ofType: "sqlite") else {
            print("[BundledLiturgicalDB] liturgical_calendar.sqlite not found in bundle")
            return
        }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            print("[BundledLiturgicalDB] Failed to open database")
            db = nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Look up liturgical data for a given date, using Pascha offset for readings
    /// and month-day for saints.
    func fetchDay(date: Date) -> OrthocalDayDTO? {
        guard let db else { return nil }

        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        let pascha = PaschalCalculator.easter(year: year)
        let paschaStart = calendar.startOfDay(for: pascha)
        let dateStart = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: paschaStart, to: dateStart).day ?? 0

        // Look up readings by Pascha offset
        var apostolDisplay: String?
        var gospelDisplay: String?
        var otherReadingsJSON: String?
        var tone: Int?
        var fasting: String?
        var summaryTitle: String?

        let moveableSQL = "SELECT apostol_display, gospel_display, other_readings_json, tone, fasting, summary_title FROM moveable_cycle WHERE pascha_offset = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, moveableSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(offset))
            if sqlite3_step(stmt) == SQLITE_ROW {
                apostolDisplay = columnText(stmt, 0)
                gospelDisplay = columnText(stmt, 1)
                otherReadingsJSON = columnText(stmt, 2)
                tone = columnInt(stmt, 3)
                fasting = columnText(stmt, 4)
                summaryTitle = columnText(stmt, 5)
            }
        }
        sqlite3_finalize(stmt)

        // Look up saints by Gregorian month-day
        var saints: [String] = []
        let saintsSQL = "SELECT saints_json FROM fixed_saints WHERE month = ? AND day = ?"
        if sqlite3_prepare_v2(db, saintsSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(month))
            sqlite3_bind_int(stmt, 2, Int32(day))
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let json = columnText(stmt, 0),
                   let data = json.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode([String].self, from: data) {
                    saints = parsed
                }
            }
        }
        sqlite3_finalize(stmt)

        // If we found neither readings nor saints, return nil
        guard apostolDisplay != nil || gospelDisplay != nil || !saints.isEmpty else {
            return nil
        }

        // Build readings array matching OrthocalReadingDTO format
        var readings: [OrthocalReadingDTO] = []

        if let apostol = apostolDisplay, !apostol.isEmpty {
            readings.append(OrthocalReadingDTO(
                source: "apostol",
                book: nil,
                description: "Апостол",
                display: apostol,
                shortDisplay: apostol,
                passage: []
            ))
        }

        if let gospel = gospelDisplay, !gospel.isEmpty {
            readings.append(OrthocalReadingDTO(
                source: "gospel",
                book: nil,
                description: "Евангелие",
                display: gospel,
                shortDisplay: gospel,
                passage: []
            ))
        }

        // Parse other readings from JSON
        if let json = otherReadingsJSON,
           let data = json.data(using: .utf8),
           let others = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            for other in others {
                readings.append(OrthocalReadingDTO(
                    source: other["source"],
                    book: nil,
                    description: nil,
                    display: other["display"],
                    shortDisplay: other["display"],
                    passage: []
                ))
            }
        }

        return OrthocalDayDTO(
            year: year,
            month: month,
            day: day,
            tone: tone,
            fastingDescription: fasting,
            fastingException: nil,
            summaryTitle: summaryTitle,
            saints: saints,
            readings: readings
        )
    }

    // MARK: - SQLite helpers

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func columnInt(_ stmt: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, index))
    }
}
