#!/usr/bin/env swift

import Accelerate
import Foundation
import ImageIO
import SQLite3
import Vision
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Configuration {
    let databasePath: String
    let imagesRootPath: String
    let outputDirectoryPath: String
    let classifierPriorsEnabled: Bool
    let manifestVersion: String
    let limit: Int?
}

struct ImageRow {
    let imageID: Int
    let iconID: Int
    let category: String
    let localThumb: String?
    let localFull: String?
}

struct RowMetadata {
    let featureRow: Int
    let imageID: Int
    let iconID: Int
    let category: String
    let localThumb: String?
    let localFull: String?
}

struct Manifest: Encodable {
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

struct Stats {
    var totalRows = 0
    var embeddedRows = 0
    var skippedMissingSource = 0
    var skippedUnreadableImage = 0
    var skippedFeaturePrint = 0
    var sourceCounts: [String: Int] = [:]
    var categoryCounts: [String: Int] = [:]
}

enum BuildError: LocalizedError {
    case invalidArguments(String)
    case openDatabase(String)
    case sqlite(String)
    case unreadableImage(String)
    case missingResources(String)
    case inconsistentFeatureDimension(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return message
        case let .openDatabase(path):
            return "Unable to open SQLite database at \(path)"
        case let .sqlite(message):
            return message
        case let .unreadableImage(path):
            return "Unable to read image at \(path)"
        case let .missingResources(path):
            return "Required resource is missing at \(path)"
        case let .inconsistentFeatureDimension(expected, actual):
            return "Feature vector dimension mismatch. Expected \(expected), got \(actual)"
        }
    }
}

final class SQLiteDatabase {
    private var db: OpaquePointer?

    init(path: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw BuildError.openDatabase(path)
        }
        db = connection
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func execute(_ sql: String) throws {
        guard let db else { throw BuildError.sqlite("Database not available") }
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite exec failed"
            sqlite3_free(errorMessage)
            throw BuildError.sqlite(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw BuildError.sqlite("Database not available") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BuildError.sqlite(lastErrorMessage())
        }
        return statement
    }

    func finalize(_ statement: OpaquePointer?) {
        sqlite3_finalize(statement)
    }

    func lastErrorMessage() -> String {
        guard let db, let error = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: error)
    }

    func columnNames(in table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            columns.insert(String(cString: name))
        }
        return columns
    }

    func ensureEmbeddingColumns() throws {
        let iconColumns = try columnNames(in: "icons")
        if !iconColumns.contains("representative_image_id") {
            try execute("ALTER TABLE icons ADD COLUMN representative_image_id INTEGER")
        }

        let imageColumns = try columnNames(in: "images")
        if !imageColumns.contains("feature_row") {
            try execute("ALTER TABLE images ADD COLUMN feature_row INTEGER")
        }
        if !imageColumns.contains("feature_source") {
            try execute("ALTER TABLE images ADD COLUMN feature_source TEXT")
        }

        try execute("CREATE INDEX IF NOT EXISTS idx_icons_representative_image ON icons(representative_image_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_images_feature_row ON images(feature_row)")
    }

    func resetEmbeddingMetadata() throws {
        try execute("UPDATE images SET feature_row = NULL, feature_source = NULL")
        try execute("UPDATE icons SET representative_image_id = NULL")
    }

    func checkpointWAL() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func fetchImageRows() throws -> [ImageRow] {
        let sql = """
        SELECT
            images.image_id,
            images.icon_id,
            icons.category,
            images.local_thumb,
            images.local_full
        FROM images
        JOIN icons ON icons.icon_id = images.icon_id
        WHERE images.local_thumb IS NOT NULL OR images.local_full IS NOT NULL
        ORDER BY images.icon_id ASC, images.ordinal ASC, images.image_id ASC
        """

        let statement = try prepare(sql)
        defer { finalize(statement) }

        var rows: [ImageRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let imageID = Int(sqlite3_column_int64(statement, 0))
            let iconID = Int(sqlite3_column_int64(statement, 1))
            let category = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "saints"
            let localThumb = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let localFull = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            rows.append(
                ImageRow(
                    imageID: imageID,
                    iconID: iconID,
                    category: category,
                    localThumb: localThumb,
                    localFull: localFull
                )
            )
        }
        return rows
    }
}

func parseArguments() throws -> Configuration {
    let rawScriptPath = CommandLine.arguments[0]
    let environment = ProcessInfo.processInfo.environment
    let invocationDirectory = environment["PWD"] ?? FileManager.default.currentDirectoryPath
    let scriptURL = URL(fileURLWithPath: rawScriptPath)
    let isInlineSwiftExecution =
        scriptURL.lastPathComponent == "main.swift" &&
        scriptURL.path.contains("/TemporaryDirectory.")
    let scriptDirectory: String
    if rawScriptPath == "-e" || isInlineSwiftExecution {
        scriptDirectory = invocationDirectory + "/Tools"
    } else {
        scriptDirectory = scriptURL.deletingLastPathComponent().path
    }

    var databasePath = environment["ICON_DB_PATH"] ?? "\(scriptDirectory)/data/icons.sqlite"
    var imagesRootPath = environment["ICON_IMAGES_ROOT"] ?? "\(scriptDirectory)/data/pravicon_images"
    let defaultOutput = URL(fileURLWithPath: scriptDirectory)
        .deletingLastPathComponent()
        .appendingPathComponent("RussianOrthodoxReader/Resources/Icons")
        .path
    var outputDirectoryPath = environment["ICON_OUTPUT_DIR"] ?? defaultOutput
    var classifierPriorsEnabled = environment["ICON_CLASSIFIER_PRIORS_ENABLED"].map { ($0 as NSString).boolValue } ?? true
    var manifestVersion = environment["ICON_MANIFEST_VERSION"] ?? "1"
    var limit = environment["ICON_LIMIT"].flatMap(Int.init)

    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--database":
            guard let value = iterator.next() else {
                throw BuildError.invalidArguments("Missing value for --database")
            }
            databasePath = value
        case "--images-root":
            guard let value = iterator.next() else {
                throw BuildError.invalidArguments("Missing value for --images-root")
            }
            imagesRootPath = value
        case "--output-dir":
            guard let value = iterator.next() else {
                throw BuildError.invalidArguments("Missing value for --output-dir")
            }
            outputDirectoryPath = value
        case "--classifier-priors-enabled":
            guard let value = iterator.next() else {
                throw BuildError.invalidArguments("Missing value for --classifier-priors-enabled")
            }
            classifierPriorsEnabled = (value as NSString).boolValue
        case "--manifest-version":
            guard let value = iterator.next() else {
                throw BuildError.invalidArguments("Missing value for --manifest-version")
            }
            manifestVersion = value
        case "--limit":
            guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                throw BuildError.invalidArguments("Missing or invalid value for --limit")
            }
            limit = parsed
        case "--help", "-h":
            throw BuildError.invalidArguments(
                """
                Usage:
                  swift Tools/build_icon_feature_index.swift [options]

                Options:
                  --database <path>                    Source SQLite database
                  --images-root <path>                 Root pravicon_images directory
                  --output-dir <path>                  Destination bundle resources directory
                  --classifier-priors-enabled <bool>   Store manifest flag (default: true)
                  --manifest-version <string>          Manifest schema version (default: 1)
                  --limit <count>                      Process only the first N images (smoke test)
                """
            )
        default:
            throw BuildError.invalidArguments("Unknown argument: \(argument)")
        }
    }

    return Configuration(
        databasePath: databasePath,
        imagesRootPath: imagesRootPath,
        outputDirectoryPath: outputDirectoryPath,
        classifierPriorsEnabled: classifierPriorsEnabled,
        manifestVersion: manifestVersion,
        limit: limit
    )
}

func imagePixelSize(at url: URL) -> (width: Int, height: Int)? {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
        return nil
    }

    let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    guard width > 0, height > 0 else { return nil }
    return (width, height)
}

func performFeaturePrint(for url: URL) throws -> [Float] {
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(url: url, options: [:])
    try handler.perform([request])

    guard let observation = request.results?.first as? VNFeaturePrintObservation else {
        throw BuildError.sqlite("Vision did not return a feature print")
    }

    return observation.data.withUnsafeBytes {
        Array($0.bindMemory(to: Float.self))
    }
}

func generateFeatureVector(at path: String) throws -> (vector: [Float], width: Int, height: Int) {
    let url = URL(fileURLWithPath: path)
    guard let size = imagePixelSize(at: url) else {
        throw BuildError.unreadableImage(path)
    }
    return (try performFeaturePrint(for: url), size.width, size.height)
}

func writeFloatArray(_ values: [Float], to url: URL) throws {
    let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    try data.write(to: url, options: .atomic)
}

func iso8601Timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

func configureStreamingOutput() {
    #if canImport(Darwin)
    setbuf(__stdoutp, nil)
    setbuf(__stderrp, nil)
    #elseif canImport(Glibc)
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    #endif
}

func main() throws {
    configureStreamingOutput()

    let configuration = try parseArguments()
    let fileManager = FileManager.default
    let outputDirectory = URL(fileURLWithPath: configuration.outputDirectoryPath, isDirectory: true)
    let thumbnailsDirectory = outputDirectory.appendingPathComponent("Thumbs", isDirectory: true)

    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
    try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true, attributes: nil)

    let database = try SQLiteDatabase(path: configuration.databasePath)
    try database.ensureEmbeddingColumns()
    try database.resetEmbeddingMetadata()

    let allImageRows = try database.fetchImageRows()
    let imageRows = configuration.limit.map { Array(allImageRows.prefix($0)) } ?? allImageRows
    guard !imageRows.isEmpty else {
        throw BuildError.missingResources("No images with local paths were found in the database.")
    }

    let updateImageStatement = try database.prepare(
        "UPDATE images SET feature_row = ?, feature_source = ? WHERE image_id = ?"
    )
    defer { database.finalize(updateImageStatement) }

    let updateRepresentativeStatement = try database.prepare(
        "UPDATE icons SET representative_image_id = ? WHERE icon_id = ?"
    )
    defer { database.finalize(updateRepresentativeStatement) }

    try database.execute("BEGIN IMMEDIATE TRANSACTION")

    var stats = Stats(totalRows: imageRows.count)
    var allVectors: [Float] = []
    var norms: [Float] = []
    var rowMetadata: [RowMetadata] = []
    var iconSums: [Int: [Float]] = [:]
    var iconCounts: [Int: Int] = [:]
    var dimension: Int?

    for row in imageRows {
        let fullPath = row.localFull.map { URL(fileURLWithPath: configuration.imagesRootPath).appendingPathComponent($0).path }
        let thumbPath = row.localThumb.map { URL(fileURLWithPath: configuration.imagesRootPath).appendingPathComponent($0).path }

        let chosenPath: String?
        let sourceLabel: String
        if let fullPath, fileManager.fileExists(atPath: fullPath) {
            chosenPath = fullPath
            sourceLabel = "full"
        } else if let thumbPath, fileManager.fileExists(atPath: thumbPath) {
            chosenPath = thumbPath
            sourceLabel = "thumb"
        } else {
            chosenPath = nil
            sourceLabel = ""
        }

        guard let chosenPath else {
            stats.skippedMissingSource += 1
            if stats.skippedMissingSource <= 3 {
                print("Missing source for image \(row.imageID)")
            }
            continue
        }

        let featureResult: (vector: [Float], width: Int, height: Int)
        do {
            featureResult = try generateFeatureVector(at: chosenPath)
        } catch {
            if case BuildError.unreadableImage = error {
                stats.skippedUnreadableImage += 1
                if stats.skippedUnreadableImage <= 3 {
                    print("Unreadable image \(chosenPath): \(error.localizedDescription)")
                }
            } else {
                stats.skippedFeaturePrint += 1
                if stats.skippedFeaturePrint <= 3 {
                    print("Vision failed for \(chosenPath): \(error.localizedDescription)")
                }
            }
            continue
        }
        let featureVector = featureResult.vector
        if rowMetadata.count < 3 {
            print("Encoding \(chosenPath) at \(featureResult.width)x\(featureResult.height)")
        }
        if let dimension {
            guard dimension == featureVector.count else {
                throw BuildError.inconsistentFeatureDimension(expected: dimension, actual: featureVector.count)
            }
        } else {
            dimension = featureVector.count
        }

        let featureRow = rowMetadata.count
        let normSquared = vDSP.dot(featureVector, featureVector)
        let norm = sqrt(normSquared)

        allVectors.append(contentsOf: featureVector)
        norms.append(norm)
        rowMetadata.append(
            RowMetadata(
                featureRow: featureRow,
                imageID: row.imageID,
                iconID: row.iconID,
                category: row.category,
                localThumb: row.localThumb,
                localFull: row.localFull
            )
        )

        var iconSum = iconSums[row.iconID] ?? Array(repeating: 0, count: featureVector.count)
        for index in 0..<featureVector.count {
            iconSum[index] += featureVector[index]
        }
        iconSums[row.iconID] = iconSum
        iconCounts[row.iconID, default: 0] += 1

        stats.embeddedRows += 1
        stats.sourceCounts[sourceLabel, default: 0] += 1
        stats.categoryCounts[row.category, default: 0] += 1

        sqlite3_reset(updateImageStatement)
        sqlite3_clear_bindings(updateImageStatement)
        sqlite3_bind_int64(updateImageStatement, 1, sqlite3_int64(featureRow))
        sqlite3_bind_text(updateImageStatement, 2, (sourceLabel as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(updateImageStatement, 3, sqlite3_int64(row.imageID))

        guard sqlite3_step(updateImageStatement) == SQLITE_DONE else {
            throw BuildError.sqlite(database.lastErrorMessage())
        }

        if featureRow.isMultiple(of: 250) {
            print("Embedded \(featureRow + 1) / \(imageRows.count) images...")
        }
    }

    guard let featureDimension = dimension else {
        throw BuildError.missingResources("No feature vectors were generated.")
    }

    var centroids: [Int: [Float]] = [:]
    centroids.reserveCapacity(iconSums.count)
    for (iconID, sum) in iconSums {
        guard let count = iconCounts[iconID], count > 0 else { continue }
        let scale = 1.0 / Float(count)
        var centroid = sum
        vDSP.multiply(scale, centroid, result: &centroid)
        centroids[iconID] = centroid
    }

    var representatives: [Int: (imageID: Int, distance: Float)] = [:]
    for metadata in rowMetadata {
        guard let centroid = centroids[metadata.iconID] else { continue }
        let start = metadata.featureRow * featureDimension
        var sumSquaredDifference: Float = 0
        for index in 0..<featureDimension {
            let delta = allVectors[start + index] - centroid[index]
            sumSquaredDifference += delta * delta
        }
        let distance = sqrt(sumSquaredDifference)
        if let existing = representatives[metadata.iconID], existing.distance <= distance {
            continue
        }
        representatives[metadata.iconID] = (imageID: metadata.imageID, distance: distance)
    }

    for (iconID, representative) in representatives {
        sqlite3_reset(updateRepresentativeStatement)
        sqlite3_clear_bindings(updateRepresentativeStatement)
        sqlite3_bind_int64(updateRepresentativeStatement, 1, sqlite3_int64(representative.imageID))
        sqlite3_bind_int64(updateRepresentativeStatement, 2, sqlite3_int64(iconID))

        guard sqlite3_step(updateRepresentativeStatement) == SQLITE_DONE else {
            throw BuildError.sqlite(database.lastErrorMessage())
        }
    }

    try database.execute("COMMIT TRANSACTION")
    try database.checkpointWAL()

    let vectorsURL = outputDirectory.appendingPathComponent("icon_feature_vectors.f32")
    let normsURL = outputDirectory.appendingPathComponent("icon_feature_norms.f32")
    let manifestURL = outputDirectory.appendingPathComponent("icon_feature_manifest.json")
    let bundledDatabaseURL = outputDirectory.appendingPathComponent("icons.sqlite")
    let bundledDatabaseWALURL = outputDirectory.appendingPathComponent("icons.sqlite-wal")
    let bundledDatabaseSHMURL = outputDirectory.appendingPathComponent("icons.sqlite-shm")

    try writeFloatArray(allVectors, to: vectorsURL)
    try writeFloatArray(norms, to: normsURL)

    for (iconID, representative) in representatives {
        guard let metadata = rowMetadata.first(where: { $0.imageID == representative.imageID }) else { continue }
        let relativeSource = metadata.localThumb ?? metadata.localFull
        guard let relativeSource else { continue }
        let sourceURL = URL(fileURLWithPath: configuration.imagesRootPath).appendingPathComponent(relativeSource)
        let destinationURL = thumbnailsDirectory.appendingPathComponent("\(iconID).jpg")
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    if fileManager.fileExists(atPath: bundledDatabaseURL.path) {
        try fileManager.removeItem(at: bundledDatabaseURL)
    }
    if fileManager.fileExists(atPath: bundledDatabaseWALURL.path) {
        try fileManager.removeItem(at: bundledDatabaseWALURL)
    }
    if fileManager.fileExists(atPath: bundledDatabaseSHMURL.path) {
        try fileManager.removeItem(at: bundledDatabaseSHMURL)
    }
    try fileManager.copyItem(at: URL(fileURLWithPath: configuration.databasePath), to: bundledDatabaseURL)

    let manifest = Manifest(
        version: configuration.manifestVersion,
        generatedAt: iso8601Timestamp(),
        metric: "l2",
        dimension: featureDimension,
        rowCount: rowMetadata.count,
        classifierPriorsEnabled: configuration.classifierPriorsEnabled,
        databaseFile: "icons.sqlite",
        featureFile: vectorsURL.lastPathComponent,
        normsFile: normsURL.lastPathComponent,
        thumbnailsSubdirectory: "Thumbs",
        featurePrintRevision: VNGenerateImageFeaturePrintRequest.defaultRevision,
        sourceCounts: stats.sourceCounts,
        categoryCounts: stats.categoryCounts
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

    print("")
    print("Icon feature index ready")
    print("  Output directory: \(outputDirectory.path)")
    print("  Feature rows:     \(rowMetadata.count)")
    print("  Vector dimension: \(featureDimension)")
    print("  Full-size rows:   \(stats.sourceCounts["full", default: 0])")
    print("  Thumb rows:       \(stats.sourceCounts["thumb", default: 0])")
    print("  Missing sources:  \(stats.skippedMissingSource)")
    print("  Unreadable rows:  \(stats.skippedUnreadableImage)")
    print("  Vision failures:  \(stats.skippedFeaturePrint)")
    print("  Representatives:  \(representatives.count)")
}

do {
    try main()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
