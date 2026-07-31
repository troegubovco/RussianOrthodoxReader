/// A single candidate subject match — either from the classifier's softmax
/// output or from a cosine search over the prototype index.
/// Платформо-независимые типы: их использует и кроссплатформенный PrototypeIndex.
struct IconMatch: Identifiable, Hashable {
    let iconId: Int
    let name: String
    let score: Float          // softmax prob (classifier) or cosine (prototypes)

    var id: Int { iconId }
}

enum IconRecognitionResult {
    case recognized(IconMatch, alternatives: [IconMatch])
    case suggestions([IconMatch])   // below τ — show "возможно, это…"
    case unknown
}

// Camera-based icon recognition is an iOS-only feature (UIImage/UIImagePickerController-driven).
// PrototypeIndex.swift and IconMetaRepository.swift remain cross-platform.
#if os(iOS)
import Vision
import CoreML
import UIKit

/// Wraps the bundled Core ML icon classifier + prototype index.
///
/// `IconClassifier.mlpackage`, `icon_prototypes.f32/.json` and `icon_meta.sqlite`
/// are produced by the offline training pipeline in `Tools/icon_ml/` (see
/// `Tools/icon_ml/PLAN.md`) and are not part of this checkout yet — `shared`
/// is `nil` until those artifacts are added to the app bundle, and every
/// call site must treat it as optional.
final class IconRecognizer {
    static let shared = IconRecognizer()

    // τ из work/runs/v1/eval_report.md: точность ≥0.95 на принятых, OOD-приём ≤5%.
    private let softmaxThreshold: Float = 0.60
    // Порог косинуса для prototype-подсказок; уточнить по полевым фото.
    private let cosineThreshold: Float = 0.45

    private let model: VNCoreMLModel
    private let labels: [(iconId: Int, name: String)]   // index-ordered
    private let index = PrototypeIndex()

    private init?() {
        guard let url = Bundle.main.url(forResource: "IconClassifier",
                                        withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url),
              let vn = try? VNCoreMLModel(for: ml) else { return nil }
        model = vn
        let meta = ml.modelDescription.metadata[.creatorDefinedKey]
            as? [String: String] ?? [:]
        struct L: Decodable { let i: Int; let id: Int; let n: String }
        let decoded = (try? JSONDecoder().decode(
            [L].self, from: Data((meta["labels_json"] ?? "[]").utf8))) ?? []
        labels = decoded.sorted { $0.i < $1.i }.map { ($0.id, $0.n) }
    }

    func recognize(_ image: UIImage, completion: @escaping (IconRecognitionResult) -> Void) {
        guard let cg = image.cgImage else { return completion(.unknown) }
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self,
                  let obs = req.results as? [VNCoreMLFeatureValueObservation]
            else { return completion(.unknown) }
            var probs: MLMultiArray?
            var embedding: MLMultiArray?
            for o in obs {
                if o.featureName == "probabilities" { probs = o.featureValue.multiArrayValue }
                if o.featureName == "embedding" { embedding = o.featureValue.multiArrayValue }
            }
            completion(self.decide(probs: probs, embedding: embedding))
        }
        request.imageCropAndScaleOption = .centerCrop
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cg,
                orientation: CGImagePropertyOrientation(image.imageOrientation))
            try? handler.perform([request])
        }
    }

    private func decide(probs: MLMultiArray?, embedding: MLMultiArray?) -> IconRecognitionResult {
        guard let probs else { return .unknown }
        let p = (0..<probs.count).map { Float(truncating: probs[$0]) }
        let top = p.indices.sorted { p[$0] > p[$1] }.prefix(3).map {
            IconMatch(iconId: labels[$0].iconId, name: labels[$0].name, score: p[$0])
        }
        if let best = top.first, best.score >= softmaxThreshold {
            return .recognized(best, alternatives: Array(top.dropFirst()))
        }
        // Fallback: prototype search over ALL ~3,155 subjects.
        if let embedding, let hits = index.search(embedding, topK: 5),
           let bestCos = hits.first, bestCos.score >= cosineThreshold {
            return .suggestions(hits)
        }
        return .unknown
    }
}

// MARK: - UIImage.Orientation → CGImagePropertyOrientation

private extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up:            self = .up
        case .upMirrored:     self = .upMirrored
        case .down:           self = .down
        case .downMirrored:   self = .downMirrored
        case .left:           self = .left
        case .leftMirrored:   self = .leftMirrored
        case .right:          self = .right
        case .rightMirrored:  self = .rightMirrored
        @unknown default:     self = .up
        }
    }
}
#endif
