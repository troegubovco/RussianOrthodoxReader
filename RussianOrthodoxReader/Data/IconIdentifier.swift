import Accelerate
import CoreML
import Foundation
import Vision

enum IconIdentifierError: LocalizedError {
    case missingManifest
    case missingFeatureFile(String)
    case invalidFeatureIndex
    case noMatches
    case featurePrintFailed

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "Файлы распознавания икон не найдены в bundle. Сначала соберите icon assets."
        case let .missingFeatureFile(name):
            return "Не найден ресурс \(name) для распознавания икон."
        case .invalidFeatureIndex:
            return "Индекс икон поврежден или не совпадает с базой данных."
        case .noMatches:
            return "Подходящих совпадений не найдено."
        case .featurePrintFailed:
            return "Не удалось вычислить визуальные признаки изображения."
        }
    }
}

private struct LoadedIconIndex {
    let manifest: IconFeatureManifest
    let featureRows: [IconFeatureRowRecord]
    let featureData: Data
    let norms: [Float]
}

private struct IconSearchCandidate {
    let iconID: Int
    let imageID: Int
    let rawDistance: Float
    let adjustedDistance: Float
}

nonisolated final class IconCategoryPriorClassifier {
    private let model: VNCoreMLModel?

    init() {
        let candidateURLs = [
            Bundle.main.url(forResource: "IconCategoryClassifier", withExtension: "mlmodelc"),
            Bundle.main.url(forResource: "IconClassifier 3", withExtension: "mlmodelc"),
            Bundle.main.url(forResource: "IconClassifier 2", withExtension: "mlmodelc")
        ].compactMap { $0 }

        var resolvedModel: VNCoreMLModel?
        for url in candidateURLs {
            if let mlModel = try? MLModel(contentsOf: url),
               let visionModel = try? VNCoreMLModel(for: mlModel) {
                resolvedModel = visionModel
                break
            }
        }
        model = resolvedModel
    }

    func classify(_ image: CGImage) -> IconQueryClassification? {
        guard let model else { return nil }

        var observations: [VNClassificationObservation] = []
        let request = VNCoreMLRequest(model: model) { request, _ in
            observations = request.results as? [VNClassificationObservation] ?? []
        }
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let probabilityPairs: [(IconCategory, Double)] = observations.compactMap { observation in
            guard let category = IconCategory(rawValue: observation.identifier) else {
                return nil
            }
            return (category, Double(observation.confidence))
        }
        let probabilities = Dictionary(uniqueKeysWithValues: probabilityPairs)

        let topCategory = observations.first.flatMap { IconCategory(rawValue: $0.identifier) }
        let topConfidence = observations.first.map { Double($0.confidence) }

        return IconQueryClassification(
            category: topCategory,
            confidence: topConfidence,
            probabilities: probabilities
        )
    }
}

actor IconIdentifier {
    static let shared = IconIdentifier(
        repository: .shared,
        classifier: IconCategoryPriorClassifier()
    )

    private let repository: IconRepository
    private let classifier: IconCategoryPriorClassifier
    private var loadedIndex: LoadedIconIndex?

    init(
        repository: IconRepository,
        classifier: IconCategoryPriorClassifier
    ) {
        self.repository = repository
        self.classifier = classifier
    }

    func preload() throws {
        _ = try loadIndex()
    }

    func identify(_ image: CGImage, limit: Int = 5) throws -> [IconMatch] {
        let index = try loadIndex()
        let queryVector = try makeQueryVector(from: image, expectedDimension: index.manifest.dimension)
        let classification = index.manifest.classifierPriorsEnabled ? classifier.classify(image) : nil
        let candidates = try search(
            queryVector: queryVector,
            classification: classification,
            index: index,
            limit: max(limit, 1)
        )

        let metadata = repository.metadata(for: candidates.map(\.iconID))
        let results: [IconMatch] = candidates.compactMap { candidate in
            guard let icon = metadata[candidate.iconID] else { return nil }
            let similarity = Self.similarityScore(for: candidate.rawDistance)
            return IconMatch(
                iconID: candidate.iconID,
                bestImageID: candidate.imageID,
                distance: Double(candidate.rawDistance),
                similarityScore: similarity,
                classifierCategory: classification?.category,
                classifierConfidence: classification?.confidence,
                name: icon.name,
                category: icon.category,
                feastDays: icon.feastDays,
                biography: icon.biography,
                representativeThumbnailName: icon.representativeThumbnailName
            )
        }

        guard !results.isEmpty else {
            throw IconIdentifierError.noMatches
        }
        return results
    }

    private func loadIndex() throws -> LoadedIconIndex {
        if let loadedIndex {
            return loadedIndex
        }

        guard let manifest = repository.loadManifest() else {
            throw IconIdentifierError.missingManifest
        }

        guard let featureURL = IconAssetLocator.featureFileURL(named: manifest.featureFile) else {
            throw IconIdentifierError.missingFeatureFile(manifest.featureFile)
        }
        guard let normsURL = IconAssetLocator.featureFileURL(named: manifest.normsFile) else {
            throw IconIdentifierError.missingFeatureFile(manifest.normsFile)
        }

        let featureRows = repository.loadFeatureRows()
        guard featureRows.count == manifest.rowCount else {
            throw IconIdentifierError.invalidFeatureIndex
        }

        let featureData = try Data(contentsOf: featureURL, options: .mappedIfSafe)
        let normsData = try Data(contentsOf: normsURL, options: .mappedIfSafe)
        let norms = normsData.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }

        guard norms.count == manifest.rowCount else {
            throw IconIdentifierError.invalidFeatureIndex
        }

        let expectedFloatCount = manifest.rowCount * manifest.dimension
        let actualFloatCount = featureData.count / MemoryLayout<Float>.stride
        guard actualFloatCount == expectedFloatCount else {
            throw IconIdentifierError.invalidFeatureIndex
        }

        let index = LoadedIconIndex(
            manifest: manifest,
            featureRows: featureRows,
            featureData: featureData,
            norms: norms
        )
        loadedIndex = index
        return index
    }

    private func makeQueryVector(from image: CGImage, expectedDimension: Int) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw IconIdentifierError.featurePrintFailed
        }

        let query = observation.data.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }

        guard query.count == expectedDimension else {
            throw IconIdentifierError.invalidFeatureIndex
        }
        return query
    }

    private func search(
        queryVector: [Float],
        classification: IconQueryClassification?,
        index: LoadedIconIndex,
        limit: Int
    ) throws -> [IconSearchCandidate] {
        let rowCount = index.manifest.rowCount
        let dimension = index.manifest.dimension
        let queryNormSquared = vDSP.dot(queryVector, queryVector)
        let baselineProbability = 1.0 / Float(IconCategory.allCases.count)
        var dotProducts = [Float](repeating: 0, count: rowCount)

        try index.featureData.withUnsafeBytes { rawBuffer in
            let matrix = rawBuffer.bindMemory(to: Float.self)
            guard let matrixBase = matrix.baseAddress else {
                throw IconIdentifierError.invalidFeatureIndex
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

        var bestByIcon: [Int: IconSearchCandidate] = [:]
        bestByIcon.reserveCapacity(limit * 4)

        for rowIndex in 0..<rowCount {
            let metadata = index.featureRows[rowIndex]
            let rowNorm = index.norms[rowIndex]
            let distanceSquared = max(0, rowNorm * rowNorm + queryNormSquared - (2 * dotProducts[rowIndex]))
            let rawDistance = sqrt(distanceSquared)
            let adjustedDistance = applyClassifierPrior(
                rawDistance: rawDistance,
                category: metadata.category,
                classification: classification,
                baselineProbability: baselineProbability
            )

            let candidate = IconSearchCandidate(
                iconID: metadata.iconID,
                imageID: metadata.imageID,
                rawDistance: rawDistance,
                adjustedDistance: adjustedDistance
            )

            if let existing = bestByIcon[metadata.iconID], existing.adjustedDistance <= candidate.adjustedDistance {
                continue
            }
            bestByIcon[metadata.iconID] = candidate
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

    private func applyClassifierPrior(
        rawDistance: Float,
        category: IconCategory,
        classification: IconQueryClassification?,
        baselineProbability: Float
    ) -> Float {
        guard let classification else { return rawDistance }
        let probability = Float(classification.probabilities[category] ?? 0)
        let adjustment = 1 - (0.18 * (probability - baselineProbability))
        let clamped = min(max(adjustment, 0.88), 1.12)
        return rawDistance * clamped
    }

    private static func similarityScore(for distance: Float) -> Double {
        let normalized = max(0, 1 - (Double(distance) / 2.2))
        return min(1, normalized)
    }
}
