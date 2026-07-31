import CoreML
import Accelerate

/// k-NN index over per-subject prototype embeddings (`icon_prototypes.f32/.json`
/// in the `Icons` bundle folder). Covers all ~3,155 pravicon subjects, so even
/// rare saints resolve to a ranked suggestion list when the classifier head
/// (limited to the ~430 curated classes) doesn't recognize the photo directly.
///
/// The artifacts are produced by `Tools/icon_ml/08_build_embedding_index.py`
/// and are not bundled yet — `search` simply returns `nil` until they ship.
final class PrototypeIndex {
    private var vectors: [Float] = []      // rowCount × dim, L2-normalized rows
    private var subjects: [(iconId: Int, name: String)] = []
    private var dim = 0

    init() {
        guard let jsonURL = Bundle.main.url(forResource: "icon_prototypes",
                                            withExtension: "json",
                                            subdirectory: "IconML"),
              let f32URL = Bundle.main.url(forResource: "icon_prototypes",
                                           withExtension: "f32",
                                           subdirectory: "IconML"),
              let data = try? Data(contentsOf: jsonURL),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dimension = doc["dimension"] as? Int,
              let subjectList = doc["subjects"] as? [[String: Any]],
              let raw = try? Data(contentsOf: f32URL) else { return }
        dim = dimension
        vectors = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        subjects = subjectList.compactMap {
            guard let id = $0["icon_id"] as? Int,
                  let name = $0["name"] as? String else { return nil }
            return (id, name)
        }
    }

    func search(_ query: MLMultiArray, topK: Int) -> [IconMatch]? {
        guard dim > 0, query.count == dim,
              vectors.count == subjects.count * dim else { return nil }
        var q = (0..<dim).map { Float(truncating: query[$0]) }
        var norm: Float = 0
        vDSP_svesq(q, 1, &norm, vDSP_Length(dim))
        guard norm > 0 else { return nil }
        var scale = 1 / sqrt(norm)
        vDSP_vsmul(q, 1, &scale, &q, 1, vDSP_Length(dim))

        var scores = [Float](repeating: 0, count: subjects.count)
        // scores = prototypes(rows) · q  — a single matrix-vector product
        vDSP_mmul(vectors, 1, q, 1, &scores, 1,
                  vDSP_Length(subjects.count), 1, vDSP_Length(dim))
        return scores.indices.sorted { scores[$0] > scores[$1] }.prefix(topK).map {
            IconMatch(iconId: subjects[$0].iconId,
                      name: subjects[$0].name, score: scores[$0])
        }
    }
}
