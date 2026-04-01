#!/usr/bin/env swift

import Accelerate
import CoreML
import Foundation
import ImageIO
import SQLite3
import Vision
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum EvaluationMode: String, CaseIterable {
    case retrievalOnly = "retrieval-only"
    case softPrior = "soft-prior"
    case hardFilter = "hard-filter"
}

struct EvaluationConfiguration {
    let databasePath: String
    let datasetRootPath: String
    let indexDirectoryPath: String
    let modelPath: String?
    let limit: Int?
    let modes: [EvaluationMode]
    let topKs: [Int]
}

struct EvaluationManifest: Decodable {
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

struct EvaluationFeatureRow {
    let featureRow: Int
    let imageID: Int
    let iconID: Int
    let category: String
}

struct EvaluationImageSample {
    let url: URL
    let imageID: Int
    let iconID: Int
    let category: String
}

struct EvaluationClassification {
    let category: String?
    let confidence: Double?
    let probabilities: [String: Double]
}

struct SearchResult {
    let iconID: Int
    let imageID: Int
    let rawDistance: Float
    let adjustedDistance: Float
    let category: String
}

struct ModeMetrics {
    let mode: EvaluationMode
    var total = 0
    var topHits: [Int: Int] = [:]
    var categoryTotals: [String: Int] = [:]
    var categoryTopHits: [String: [Int: Int]] = [:]
    var skippedByHardFilter = 0
    var missingClassifier = 0
    var classifierTop1Correct = 0
    var classifierEvaluations = 0
}

enum EvaluationError: LocalizedError {
    case invalidArguments(String)
    case missingResource(String)
    case openDatabase(String)
    case sqlite(String)
    case emptyDataset(String)
    case invalidFeatureIndex
    case unreadableImage(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return message
        case let .missingResource(path):
            return "Required resource is missing at \(path)"
        case let .openDatabase(path):
            return "Unable to open SQLite database at \(path)"
        case let .sqlite(message):
            return message
        case let .emptyDataset(path):
            return "No evaluation images were found under \(path)"
        case .invalidFeatureIndex:
            return "The feature index does not match the SQLite metadata."
        case let .unreadableImage(path):
            return "Unable to generate a feature print for \(path)"
        }
    }
}

final class EvaluationDatabase {
    private var db: OpaquePointer?

    init(path: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw EvaluationError.openDatabase(path)
        }
        db = connection
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw EvaluationError.sqlite("Database not available") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw EvaluationError.sqlite(lastErrorMessage())
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

    func fetchFeatureRows() throws -> [EvaluationFeatureRow] {
        let sql = """
        SELECT images.feature_row, images.image_id, images.icon_id, icons.category
        FROM images
        JOIN icons ON icons.icon_id = images.icon_id
        WHERE images.feature_row IS NOT NULL
        ORDER BY images.feature_row ASC
        """
        let statement = try prepare(sql)
        defer { finalize(statement) }

        var rows: [EvaluationFeatureRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                EvaluationFeatureRow(
                    featureRow: Int(sqlite3_column_int64(statement, 0)),
                    imageID: Int(sqlite3_column_int64(statement, 1)),
                    iconID: Int(sqlite3_column_int64(statement, 2)),
                    category: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "saints"
                )
            )
        }
        return rows
    }

    func fetchImageLookup() throws -> [Int: (iconID: Int, category: String)] {
        let sql = """
        SELECT images.image_id, images.icon_id, icons.category
        FROM images
        JOIN icons ON icons.icon_id = images.icon_id
        """
        let statement = try prepare(sql)
        defer { finalize(statement) }

        var lookup: [Int: (iconID: Int, category: String)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let imageID = Int(sqlite3_column_int64(statement, 0))
            let iconID = Int(sqlite3_column_int64(statement, 1))
            let category = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "saints"
            lookup[imageID] = (iconID: iconID, category: category)
        }
        return lookup
    }
}

final class EvaluationClassifier {
    private let model: VNCoreMLModel?

    init(modelPath: String?) {
        self.model = Self.loadModel(modelPath: modelPath)
    }

    func classify(_ cgImage: CGImage) -> EvaluationClassification? {
        guard let model else { return nil }

        var observations: [VNClassificationObservation] = []
        let request = VNCoreMLRequest(model: model) { request, _ in
            observations = request.results as? [VNClassificationObservation] ?? []
        }
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let probabilities = Dictionary(
            uniqueKeysWithValues: observations.map { ($0.identifier, Double($0.confidence)) }
        )
        return EvaluationClassification(
            category: observations.first?.identifier,
            confidence: observations.first.map { Double($0.confidence) },
            probabilities: probabilities
        )
    }

    private static func loadModel(modelPath: String?) -> VNCoreMLModel? {
        let fileManager = FileManager.default
        var candidatePaths: [String] = []
        if let modelPath {
            candidatePaths.append(modelPath)
        }

        let cwd = fileManager.currentDirectoryPath
        candidatePaths.append("\(cwd)/RussianOrthodoxReader/IconCategoryClassifier.mlmodel")
        candidatePaths.append("\(cwd)/IconClassifier.mlproj/Models/IconClassifier 3.mlmodel")
        candidatePaths.append("\(cwd)/IconClassifier.mlproj/Models/IconClassifier 2.mlmodel")

        for path in candidatePaths where fileManager.fileExists(atPath: path) {
            let sourceURL = URL(fileURLWithPath: path)
            let compiledURL: URL
            do {
                if sourceURL.pathExtension == "mlmodelc" {
                    compiledURL = sourceURL
                } else {
                    compiledURL = try MLModel.compileModel(at: sourceURL)
                }
                let model = try MLModel(contentsOf: compiledURL)
                return try VNCoreMLModel(for: model)
            } catch {
                continue
            }
        }
        return nil
    }
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

func parseArguments() throws -> EvaluationConfiguration {
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

    let projectDirectory = URL(fileURLWithPath: scriptDirectory).deletingLastPathComponent().path

    var databasePath = environment["ICON_EVAL_DB_PATH"] ?? "\(scriptDirectory)/data/icons.sqlite"
    var datasetRootPath = environment["ICON_EVAL_DATASET_ROOT"] ?? "\(scriptDirectory)/data/ml_dataset/testing_FS"
    var indexDirectoryPath = environment["ICON_EVAL_INDEX_DIR"] ?? "\(projectDirectory)/RussianOrthodoxReader/Resources/Icons"
    var modelPath = environment["ICON_EVAL_MODEL_PATH"]
    var limit = environment["ICON_EVAL_LIMIT"].flatMap(Int.init)
    var modes = environment["ICON_EVAL_MODES"]?
        .split(separator: ",")
        .compactMap { EvaluationMode(rawValue: String($0)) } ?? EvaluationMode.allCases
    var topKs = environment["ICON_EVAL_TOPKS"]?
        .split(separator: ",")
        .compactMap { Int($0) }
        .filter { $0 > 0 } ?? [1, 3, 5]

    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--database":
            guard let value = iterator.next() else {
                throw EvaluationError.invalidArguments("Missing value for --database")
            }
            databasePath = value
        case "--dataset-root":
            guard let value = iterator.next() else {
                throw EvaluationError.invalidArguments("Missing value for --dataset-root")
            }
            datasetRootPath = value
        case "--index-dir":
            guard let value = iterator.next() else {
                throw EvaluationError.invalidArguments("Missing value for --index-dir")
            }
            indexDirectoryPath = value
        case "--model":
            guard let value = iterator.next() else {
                throw EvaluationError.invalidArguments("Missing value for --model")
            }
            modelPath = value
        case "--limit":
            guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                throw EvaluationError.invalidArguments("Missing or invalid value for --limit")
            }
            limit = parsed
        case "--modes":
            guard let value = iterator.next() else {
                throw EvaluationError.invalidArguments("Missing value for --modes")
            }
            let parsedModes = value.split(separator: ",").compactMap { EvaluationMode(rawValue: String($0)) }
            guard !parsedModes.isEmpty else {
                throw EvaluationError.invalidArguments("No valid modes were supplied.")
            }
            modes = parsedModes
        case "--topk":
            guard let value = iterator.next() else {
                throw EvaluationError.invalidArguments("Missing value for --topk")
            }
            let parsedTopKs = value.split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }
            guard !parsedTopKs.isEmpty else {
                throw EvaluationError.invalidArguments("No valid top-k values were supplied.")
            }
            topKs = parsedTopKs
        case "--help", "-h":
            throw EvaluationError.invalidArguments(
                """
                Usage:
                  swift Tools/evaluate_icon_identifier.swift [options]

                Options:
                  --database <path>      SQLite database with feature_row metadata
                  --dataset-root <path>  Holdout dataset root (testing_FS)
                  --index-dir <path>     Directory containing manifest and .f32 files
                  --model <path>         Optional classifier model (.mlmodel or .mlmodelc)
                  --limit <count>        Evaluate only the first N images
                  --modes <list>         Comma-separated modes: retrieval-only,soft-prior,hard-filter
                  --topk <list>          Comma-separated icon-level cutoffs (default: 1,3,5)
                """
            )
        default:
            throw EvaluationError.invalidArguments("Unknown argument: \(argument)")
        }
    }

    topKs = Array(Set(topKs)).sorted()
    return EvaluationConfiguration(
        databasePath: databasePath,
        datasetRootPath: datasetRootPath,
        indexDirectoryPath: indexDirectoryPath,
        modelPath: modelPath,
        limit: limit,
        modes: modes,
        topKs: topKs
    )
}

func loadManifest(indexDirectory: URL) throws -> EvaluationManifest {
    let manifestURL = indexDirectory.appendingPathComponent("icon_feature_manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        throw EvaluationError.missingResource(manifestURL.path)
    }
    let data = try Data(contentsOf: manifestURL)
    return try JSONDecoder().decode(EvaluationManifest.self, from: data)
}

func loadIndex(
    configuration: EvaluationConfiguration
) throws -> (manifest: EvaluationManifest, rows: [EvaluationFeatureRow], featureData: Data, norms: [Float]) {
    let indexDirectory = URL(fileURLWithPath: configuration.indexDirectoryPath, isDirectory: true)
    let manifest = try loadManifest(indexDirectory: indexDirectory)

    let databaseURL = indexDirectory.appendingPathComponent(manifest.databaseFile)
    let databasePath: String
    if FileManager.default.fileExists(atPath: databaseURL.path) {
        databasePath = databaseURL.path
    } else {
        databasePath = configuration.databasePath
    }

    let database = try EvaluationDatabase(path: databasePath)
    let rows = try database.fetchFeatureRows()
    guard rows.count == manifest.rowCount else {
        throw EvaluationError.invalidFeatureIndex
    }

    let featureURL = indexDirectory.appendingPathComponent(manifest.featureFile)
    let normsURL = indexDirectory.appendingPathComponent(manifest.normsFile)
    guard FileManager.default.fileExists(atPath: featureURL.path) else {
        throw EvaluationError.missingResource(featureURL.path)
    }
    guard FileManager.default.fileExists(atPath: normsURL.path) else {
        throw EvaluationError.missingResource(normsURL.path)
    }

    let featureData = try Data(contentsOf: featureURL, options: .mappedIfSafe)
    let normsData = try Data(contentsOf: normsURL, options: .mappedIfSafe)
    let norms = normsData.withUnsafeBytes { rawBuffer in
        Array(rawBuffer.bindMemory(to: Float.self))
    }

    let expectedFloatCount = manifest.rowCount * manifest.dimension
    let actualFloatCount = featureData.count / MemoryLayout<Float>.stride
    guard actualFloatCount == expectedFloatCount, norms.count == manifest.rowCount else {
        throw EvaluationError.invalidFeatureIndex
    }

    return (manifest: manifest, rows: rows, featureData: featureData, norms: norms)
}

func discoverEvaluationSamples(
    configuration: EvaluationConfiguration,
    imageLookup: [Int: (iconID: Int, category: String)]
) throws -> [EvaluationImageSample] {
    let datasetRoot = URL(fileURLWithPath: configuration.datasetRootPath, isDirectory: true)
    guard FileManager.default.fileExists(atPath: datasetRoot.path) else {
        throw EvaluationError.missingResource(datasetRoot.path)
    }

    let allowedExtensions = Set(["jpg", "jpeg", "png", "heic"])
    let enumerator = FileManager.default.enumerator(
        at: datasetRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )

    var samples: [EvaluationImageSample] = []
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { continue }
        guard let imageID = Int(url.deletingPathExtension().lastPathComponent),
              let lookup = imageLookup[imageID] else {
            continue
        }

        samples.append(
            EvaluationImageSample(
                url: url,
                imageID: imageID,
                iconID: lookup.iconID,
                category: lookup.category
            )
        )
    }

    samples.sort { lhs, rhs in
        if lhs.category == rhs.category {
            return lhs.imageID < rhs.imageID
        }
        return lhs.category < rhs.category
    }

    if let limit = configuration.limit {
        samples = Array(samples.prefix(limit))
    }

    guard !samples.isEmpty else {
        throw EvaluationError.emptyDataset(datasetRoot.path)
    }

    return samples
}

func makeFeatureVector(for url: URL, expectedDimension: Int) throws -> [Float] {
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(url: url, options: [:])
    try handler.perform([request])

    guard let observation = request.results?.first as? VNFeaturePrintObservation else {
        throw EvaluationError.unreadableImage(url.path)
    }

    let query = observation.data.withUnsafeBytes {
        Array($0.bindMemory(to: Float.self))
    }
    guard query.count == expectedDimension else {
        throw EvaluationError.invalidFeatureIndex
    }
    return query
}

func loadCGImage(url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func applySoftPrior(rawDistance: Float, category: String, classification: EvaluationClassification?) -> Float {
    guard let classification else { return rawDistance }
    let baselineProbability = 1.0 / Float(max(classification.probabilities.count, 4))
    let probability = Float(classification.probabilities[category] ?? 0)
    let adjustment = 1 - (0.18 * (probability - baselineProbability))
    let clamped = min(max(adjustment, 0.88), 1.12)
    return rawDistance * clamped
}

func searchIndex(
    queryVector: [Float],
    classification: EvaluationClassification?,
    mode: EvaluationMode,
    featureData: Data,
    norms: [Float],
    rows: [EvaluationFeatureRow],
    dimension: Int,
    limit: Int
) throws -> [SearchResult] {
    let rowCount = rows.count
    let queryNormSquared = vDSP.dot(queryVector, queryVector)
    var dotProducts = [Float](repeating: 0, count: rowCount)

    try featureData.withUnsafeBytes { rawBuffer in
        let matrix = rawBuffer.bindMemory(to: Float.self)
        guard let matrixBase = matrix.baseAddress else {
            throw EvaluationError.invalidFeatureIndex
        }

        queryVector.withUnsafeBufferPointer { queryBuffer in
            dotProducts.withUnsafeMutableBufferPointer { dotsBuffer in
                guard let queryBase = queryBuffer.baseAddress,
                      let dotsBase = dotsBuffer.baseAddress else {
                    return
                }
                cblas_sgemv(
                    CblasRowMajor,
                    CblasNoTrans,
                    Int32(rowCount),
                    Int32(dimension),
                    1.0,
                    matrixBase,
                    Int32(dimension),
                    queryBase,
                    1,
                    0.0,
                    dotsBase,
                    1
                )
            }
        }
    }

    let allowedCategory = mode == .hardFilter ? classification?.category : nil
    var bestByIcon: [Int: SearchResult] = [:]
    bestByIcon.reserveCapacity(limit * 4)

    for rowIndex in 0..<rowCount {
        let row = rows[rowIndex]
        if let allowedCategory, row.category != allowedCategory {
            continue
        }

        let rowNorm = norms[rowIndex]
        let distanceSquared = max(0, rowNorm * rowNorm + queryNormSquared - (2 * dotProducts[rowIndex]))
        let rawDistance = sqrt(distanceSquared)
        let adjustedDistance: Float
        switch mode {
        case .retrievalOnly, .hardFilter:
            adjustedDistance = rawDistance
        case .softPrior:
            adjustedDistance = applySoftPrior(
                rawDistance: rawDistance,
                category: row.category,
                classification: classification
            )
        }

        let result = SearchResult(
            iconID: row.iconID,
            imageID: row.imageID,
            rawDistance: rawDistance,
            adjustedDistance: adjustedDistance,
            category: row.category
        )

        if let existing = bestByIcon[row.iconID], existing.adjustedDistance <= result.adjustedDistance {
            continue
        }
        bestByIcon[row.iconID] = result
    }

    return bestByIcon.values
        .sorted { lhs, rhs in
            if lhs.adjustedDistance == rhs.adjustedDistance {
                return lhs.rawDistance < rhs.rawDistance
            }
            return lhs.adjustedDistance < rhs.adjustedDistance
        }
        .prefix(limit)
        .map { $0 }
}

func percent(_ numerator: Int, _ denominator: Int) -> String {
    guard denominator > 0 else { return "0.0%" }
    return String(format: "%.1f%%", (Double(numerator) / Double(denominator)) * 100)
}

func printMetrics(_ metrics: ModeMetrics, topKs: [Int]) {
    print("")
    print("Mode: \(metrics.mode.rawValue)")
    print("  Samples: \(metrics.total)")
    for topK in topKs {
        print("  Icon top-\(topK): \(metrics.topHits[topK, default: 0]) / \(metrics.total) (\(percent(metrics.topHits[topK, default: 0], metrics.total)))")
    }

    if metrics.classifierEvaluations > 0 {
        print("  Classifier top-1: \(metrics.classifierTop1Correct) / \(metrics.classifierEvaluations) (\(percent(metrics.classifierTop1Correct, metrics.classifierEvaluations)))")
    }
    if metrics.mode == .hardFilter {
        print("  Hard-filter empty results: \(metrics.skippedByHardFilter)")
    }
    if metrics.missingClassifier > 0 {
        print("  Missing classifier predictions: \(metrics.missingClassifier)")
    }

    let sortedCategories = metrics.categoryTotals.keys.sorted()
    if !sortedCategories.isEmpty {
        print("  By category:")
        for category in sortedCategories {
            let total = metrics.categoryTotals[category, default: 0]
            let hits = metrics.categoryTopHits[category] ?? [:]
            let perTopK = topKs.map { topK in
                "top-\(topK) \(percent(hits[topK, default: 0], total))"
            }.joined(separator: ", ")
            print("    \(category): \(total) samples, \(perTopK)")
        }
    }
}

func main() throws {
    configureStreamingOutput()

    let configuration = try parseArguments()
    let loadedIndex = try loadIndex(configuration: configuration)
    let database = try EvaluationDatabase(path: configuration.databasePath)
    let imageLookup = try database.fetchImageLookup()
    let samples = try discoverEvaluationSamples(configuration: configuration, imageLookup: imageLookup)
    let classifier = EvaluationClassifier(modelPath: configuration.modelPath)
    let maxTopK = configuration.topKs.max() ?? 5

    print("Evaluating \(samples.count) holdout images")
    print("  Dataset: \(configuration.datasetRootPath)")
    print("  Index:   \(configuration.indexDirectoryPath)")
    print("  Modes:   \(configuration.modes.map(\.rawValue).joined(separator: ", "))")

    var metricsByMode = Dictionary(
        uniqueKeysWithValues: configuration.modes.map { ($0, ModeMetrics(mode: $0)) }
    )

    for (sampleIndex, sample) in samples.enumerated() {
        let queryVector = try makeFeatureVector(for: sample.url, expectedDimension: loadedIndex.manifest.dimension)
        let cgImage = loadCGImage(url: sample.url)
        let classification = cgImage.flatMap { classifier.classify($0) }

        for mode in configuration.modes {
            var metrics = metricsByMode[mode] ?? ModeMetrics(mode: mode)
            metrics.total += 1
            metrics.categoryTotals[sample.category, default: 0] += 1

            if let classification {
                metrics.classifierEvaluations += 1
                if classification.category == sample.category {
                    metrics.classifierTop1Correct += 1
                }
            } else if mode != .retrievalOnly {
                metrics.missingClassifier += 1
            }

            let results = try searchIndex(
                queryVector: queryVector,
                classification: classification,
                mode: mode,
                featureData: loadedIndex.featureData,
                norms: loadedIndex.norms,
                rows: loadedIndex.rows,
                dimension: loadedIndex.manifest.dimension,
                limit: maxTopK
            )

            if results.isEmpty && mode == .hardFilter {
                metrics.skippedByHardFilter += 1
            }

            let iconIDs = results.map(\.iconID)
            for topK in configuration.topKs {
                let didHit = iconIDs.prefix(topK).contains(sample.iconID)
                if didHit {
                    metrics.topHits[topK, default: 0] += 1
                    var categoryHits = metrics.categoryTopHits[sample.category] ?? [:]
                    categoryHits[topK, default: 0] += 1
                    metrics.categoryTopHits[sample.category] = categoryHits
                }
            }

            metricsByMode[mode] = metrics
        }

        if sampleIndex == 0 || (sampleIndex + 1).isMultiple(of: 50) || sampleIndex == samples.count - 1 {
            print("Processed \(sampleIndex + 1) / \(samples.count) images...")
        }
    }

    for mode in configuration.modes {
        if let metrics = metricsByMode[mode] {
            printMetrics(metrics, topKs: configuration.topKs)
        }
    }
}

do {
    try main()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
