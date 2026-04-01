import Foundation
import SQLite3

enum IconCategory: String, CaseIterable, Codable, Hashable {
    case angels
    case christ
    case saints
    case theotokos

    var title: String {
        switch self {
        case .angels:
            return "Ангелы"
        case .christ:
            return "Христос"
        case .saints:
            return "Святые"
        case .theotokos:
            return "Богородица"
        }
    }
}

struct IconFeatureManifest: Codable, Hashable {
    let version: String
    let generatedAt: String
    let metric: String
    let dimension: Int
    let rowCount: Int
    let classifierPriorsEnabled: Bool
    let databaseFile: String
    let featureFile: String
    let normsFile: String
    let thumbnailsSubdirectory: String
    let featurePrintRevision: Int
    let sourceCounts: [String: Int]
    let categoryCounts: [String: Int]
}

struct IconFeatureRowRecord: Hashable {
    let featureRow: Int
    let imageID: Int
    let iconID: Int
    let category: IconCategory
}

struct IconMetadata: Hashable {
    let iconID: Int
    let name: String
    let category: IconCategory
    let feastDays: [String]
    let biography: String
    let representativeImageID: Int?
    let representativeThumbnailName: String?
}

struct IconQueryClassification: Hashable {
    let category: IconCategory?
    let confidence: Double?
    let probabilities: [IconCategory: Double]
}

struct IconMatch: Identifiable, Hashable {
    let iconID: Int
    let bestImageID: Int
    let distance: Double
    let similarityScore: Double
    let classifierCategory: IconCategory?
    let classifierConfidence: Double?
    let name: String
    let category: IconCategory
    let feastDays: [String]
    let biography: String
    let representativeThumbnailName: String?

    var id: Int { iconID }
}

enum IconAssetLocator {
    private static let rootSubdirectories: [String?] = ["Icons", "Resources/Icons", nil]

    nonisolated static func rootResourceURL(name: String, withExtension ext: String) -> URL? {
        for subdirectory in rootSubdirectories {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        return nil
    }

    nonisolated static func databaseURL() -> URL? {
        rootResourceURL(name: "icons", withExtension: "sqlite")
    }

    nonisolated static func manifestURL() -> URL? {
        rootResourceURL(name: "icon_feature_manifest", withExtension: "json")
    }

    nonisolated static func featureFileURL(named fileName: String) -> URL? {
        let url = URL(fileURLWithPath: fileName)
        return rootResourceURL(name: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension)
    }

    nonisolated static func representativeThumbnailURL(fileName: String) -> URL? {
        let resourceURL = URL(fileURLWithPath: fileName)
        let resourceName = resourceURL.deletingPathExtension().lastPathComponent
        let ext = resourceURL.pathExtension.isEmpty ? "jpg" : resourceURL.pathExtension
        let thumbnailSubdirectories: [String?] = ["Icons/Thumbs", "Resources/Icons/Thumbs", "Thumbs", nil]

        for subdirectory in thumbnailSubdirectories {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        return nil
    }
}

nonisolated final class IconRepository {
    static let shared = IconRepository()

    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        openDatabase()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func loadManifest() -> IconFeatureManifest? {
        guard let url = IconAssetLocator.manifestURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(IconFeatureManifest.self, from: data)
    }

    func loadFeatureRows() -> [IconFeatureRowRecord] {
        guard let db else { return [] }
        let sql = """
        SELECT images.feature_row, images.image_id, images.icon_id, icons.category
        FROM images
        JOIN icons ON icons.icon_id = images.icon_id
        WHERE images.feature_row IS NOT NULL
        ORDER BY images.feature_row ASC
        """

        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var records: [IconFeatureRowRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let featureRow = Int(sqlite3_column_int64(statement, 0))
            let imageID = Int(sqlite3_column_int64(statement, 1))
            let iconID = Int(sqlite3_column_int64(statement, 2))
            let rawCategory = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? IconCategory.saints.rawValue
            let category = IconCategory(rawValue: rawCategory) ?? .saints
            records.append(
                IconFeatureRowRecord(
                    featureRow: featureRow,
                    imageID: imageID,
                    iconID: iconID,
                    category: category
                )
            )
        }
        return records
    }

    func metadata(for iconIDs: [Int]) -> [Int: IconMetadata] {
        guard let db, !iconIDs.isEmpty else { return [:] }
        let placeholders = iconIDs.map { _ in "?" }.joined(separator: ", ")
        let sql = """
        SELECT icon_id, name, category, feast_days_json, biography, representative_image_id
        FROM icons
        WHERE icon_id IN (\(placeholders))
        """

        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        for (index, iconID) in iconIDs.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), sqlite3_int64(iconID))
        }

        var results: [Int: IconMetadata] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let iconID = Int(sqlite3_column_int64(statement, 0))
            let name = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "Неизвестная икона"
            let rawCategory = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? IconCategory.saints.rawValue
            let category = IconCategory(rawValue: rawCategory) ?? .saints
            let feastDaysJSON = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "[]"
            let biography = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let representativeImageID: Int?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                representativeImageID = nil
            } else {
                representativeImageID = Int(sqlite3_column_int64(statement, 5))
            }

            let feastDays = decodeFeastDays(from: feastDaysJSON)
            let thumbnailName = representativeImageID.map { _ in "\(iconID).jpg" }

            results[iconID] = IconMetadata(
                iconID: iconID,
                name: name,
                category: category,
                feastDays: feastDays,
                biography: biography,
                representativeImageID: representativeImageID,
                representativeThumbnailName: thumbnailName
            )
        }

        return results
    }

    private func openDatabase() {
        guard let url = IconAssetLocator.databaseURL() else { return }
        var connection: OpaquePointer?
        if sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = connection
        } else if let connection {
            sqlite3_close(connection)
        }
    }

    private func decodeFeastDays(from json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let feastDays = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return feastDays
    }
}
