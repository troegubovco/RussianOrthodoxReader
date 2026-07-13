# Распознавание икон — полный план действий

*Prepared 2026-07-01. Everything below was designed against the actual state
of this repo, and every script was executed end-to-end on this Mac (M5 Pro,
64 GB, macOS 26.5, Python 3.12) on a small subset — including Core ML export
with a bit-level parity check. You can run the commands as written.*

---

## 1. Goal

Point the phone at an icon (in a church, at home, in a book) and get, fully
offline:

1. **Кто изображён** — which saint / which Theotokos type / which feast
2. **Житие святого** — shared across all icons of that saint
3. **История иконы** — for named icon types (Казанская, Владимирская, …)
4. **Молитвы** — тропарь, кондак, молитва, величание for that subject

ML identifies the *subject* (1); a bundled SQLite DB provides (2)–(4). This
mirrors the app's existing architecture (bundled `liturgical_calendar.sqlite`,
dictionary DB) — no network needed at runtime.

## 2. What already exists (audit, 2026-07-01)

| Asset | State | Verdict |
|---|---|---|
| Pravicon scrape: 3,158 subjects (2,324 saints, 738 theotokos, 84 christ, 12 angels) with names, feast days, keywords, short bios | `Tools/data/pravicon_details.json` | Reuse as the class catalog |
| 32,053 downloaded full-size images (15 GB) | `Tools/data/pravicon_images/full/` | The training corpus |
| Images per subject: 430 subjects ≥20 imgs (16.4k), 962 ≥10 (23.5k), max ~76 | measured by `01_build_manifest.py` | v1 classifier = the ≥20 set |
| Create ML experiments (4 coarse classes) | `IconClassifier.mlproj` | **86.8% on 4 classes** → Apple's fixed FeaturePrint extractor is too weak for icons; per-saint ID needs a fine-tuned network. Keep as baseline, don't extend |
| Vision FeaturePrint index: 32,037 × 768 f32 (98 MB) in `Resources/Icons/` | generated 31.03, no Swift code reads it | **Replace** with trained 512-d prototype index (~6 MB, far better features) |
| `icons.sqlite` (15.6 MB) bundled with FTS | `Resources/Icons/` | Keep — UI browsing/search; new `icon_meta.sqlite` adds lives/prayers |
| Pravicon bios | truncated at ~1000–2000 chars by scraper | Azbyka.ru gives full texts (verified: 7.5k-char life, 13.5k-char icon history) |

## 3. Architecture

```
                       ┌─ probabilities (430 classes, softmax)
photo ── IconClassifier.mlpackage ──┤
        (ConvNeXt-T fine-tuned,     └─ embedding (512-d, L2-normalized)
         256×256, FP16, ~57 MB)              │
                                             │ cosine vs 3,155 prototypes
   p_max ≥ τ ──────► RECOGNIZED              │ (icon_prototypes.f32, ~6 MB)
   p_max < τ ──────► top-5 similar subjects ◄┘
   cos_max < τ_cos ► "не распознано" + top-3 "похожие"

recognized icon_id ──► icon_meta.sqlite ──► житие / история / молитвы
```

One network, two heads:

- **Classifier head** (cosine/NormSoftmax) over the ~430 curated subjects
  users actually photograph — high-confidence direct answers.
- **Embedding output** — k-NN over per-subject prototype vectors covering
  ALL 3,155 subjects, so даже редкий святой resolves to a ranked suggestion
  list, and new subjects can be added *without retraining* (just add a
  prototype). This also powers "похожие иконы".

Both heads share weights, ship in one .mlpackage, and the prototype index is
15× smaller and dramatically stronger than the current FeaturePrint index.

### Key decisions and why

| Decision | Why |
|---|---|
| **PyTorch + timm fine-tune, not Create ML** | Create ML's frozen extractor got 86.8% on FOUR classes. Fine-grained 430-class ID needs the backbone to learn icon-specific cues (inscriptions, vestments, attributes) |
| `convnext_tiny.fb_in22k_ft_in1k` @ 256px | Strong in22k pretrain, stable fine-tuning, fast on MPS, clean Core ML conversion (parity verified Δ=0.0004). Alt: `--model tf_efficientnetv2_s.in21k_ft_in1k --img-size 288` |
| **No horizontal flip** in augmentation | Icons carry Church Slavonic inscriptions and oriented blessing gestures; mirroring destroys the most discriminative cues |
| **Glare augmentation** (custom) | #1 nuisance in real photos: glass reflections, riza metal, candlelight. Synthetic elliptical highlights close the domain gap |
| **Dedupe BEFORE splitting** (pHash) | Pravicon has many re-photographs of the same icon; leakage into test would fake the accuracy numbers |
| Cross-subject near-dup detection | The same photo filed under two subjects poisons training — flagged and excluded automatically |
| **Classes = subjects with ≥20 images** (~430) | Below that, per-class test sets are too small to trust. The tail is served by prototypes. Widen later via `--min-images 15|10` |
| Junk galleries («Разное», «фотографии реликвий») | Excluded from classes; reused as OOD samples to calibrate the rejection threshold |
| **Open-set rejection** (τ on max softmax) | A guessing model is worse than «не распознано». τ is calibrated by `06_evaluate.py` against real OOD images |
| Labels keyed by **pravicon icon_id** | Stable join key across model ↔ prototypes ↔ icon_meta.sqlite ↔ existing icons.sqlite |

## 4. Execution plan

Everything runs from `Tools/icon_ml/`, commands in [README.md](README.md).
The venv is already created and all dependencies installed (torch 2.5.1,
coremltools 8.1 — this exact pairing passed conversion parity on this Mac).

### Phase A — Data (~15 min CPU, can run any time)

| Step | What | Success criterion |
|---|---|---|
| `01_build_manifest.py` | maps 32k images → subjects, flags multi-subject images | ~32,053 rows, 3,155 subjects (already verified) |
| `02_make_cache.py` | 512px JPEG cache (~1.5 GB) for 5–10× faster epochs | 32k files in `work/cache512` |
| `03_dedupe.py` | pHash dedupe + cross-subject ambiguity flags | expect roughly 5–15% dropped; read `work/dedupe_report.txt` |
| `04_make_splits.py --min-images 20` | classes, stratified splits, OOD pool | ~420–430 classes; train ≈ 12–14k |

**Optional step A0 — deepen the head classes (+~3,100 images, recommended).**
The original details scrape used `--max-image-pages 3` (≈75 images cap). 54
subjects have more on pravicon — and they are exactly the most-photographed
ones (Казанская +362, Николай Чудотворец +307, Владимирская +187, Спас
Вседержитель +169, Архангел Михаил +167…). No tail subject gains eligibility
from this (verified: 0 subjects at 5–19 scraped have ≥20 on pravicon), so it
purely fattens the classes users will hit most. From the repo root:

```bash
python3 - <<'EOF'
import json
p = 'Tools/data/pravicon_details.json'
d = json.load(open(p))
keep = [e for e in d if e.get('total_images', 0) <= len(e.get('thumbnails', []))]
print('will re-scrape', len(d) - len(keep), 'capped subjects')
json.dump(keep, open(p, 'w'), ensure_ascii=False, indent=2)
EOF
python3 Tools/scrape_pravicon_details.py --max-image-pages 20   # ~15 min
python3 Tools/download_pravicon_images.py                       # resume-safe, new files only
```

Then run Phase A steps 01–04 (or re-run them — everything is idempotent).

### Phase B — Model (MPS; run when your other training finishes)

| Step | What | Expect |
|---|---|---|
| `05_train.py --run-name v1` | 2 frozen epochs + 28 fine-tune, cosine LR, weighted sampler | ~1–2 min/epoch on M5 Pro ⇒ under an hour. Watch `val_top1` climb past ~0.8 |
| `06_evaluate.py --checkpoint work/runs/v1/best.pt` | test metrics + **rejection threshold τ** | Target: **top-1 ≥ 85–90%**, top-5 ≥ 95% on test. Read `eval_report.md`, note recommended τ |
| `07_export_coreml.py --checkpoint …` | .mlpackage, FP16, labels embedded, **parity check** | "PARITY OK". Add `--palettize-bits 6` for a ~20 MB variant — re-check parity + eval before choosing it |
| `08_build_embedding_index.py --checkpoint …` | prototypes for all 3,155 subjects | `icon_prototypes.f32` ≈ 6.2 MB (3155×512×4) |

If a first run disappoints (<80% top-1): raise `--min-images` to 30 (fewer,
cleaner classes), or train longer (`--epochs 45`), or switch to
`tf_efficientnetv2_s.in21k_ft_in1k --img-size 288` (stronger at higher res).

### Phase C — Content (network; ~2 h incl. manual review)

1. `09_scrape_azbyka.py --probe` — 2-request self-test (passed 2026-07-01).
2. `09_scrape_azbyka.py --match` — guesses `sv-{slug}` / `ikona-{slug}` URLs
   for every class, verifies by page title. Expect 60–85% auto-matched.
3. **Manual review** of `work/azbyka_match.csv` (30–60 min): rows with status
   `check`/`notfound` → find the right page (site search:
   `https://azbyka.ru/days/search?keywords=<имя>`), paste URL, set status
   `manual`. Rows you leave unresolved simply fall back to pravicon short
   texts — nothing breaks.
4. `09_scrape_azbyka.py --scrape` → full lives, icon histories, prayers with
   глас markings.
5. `10_build_meta_db.py` → `icon_meta.sqlite` (~5–12 MB; already verified at
   5.0 MB with pravicon-only fallback content). Check the printed coverage:
   aim for 95%+ classes with text, 80%+ with prayers.

### Phase D — Release

`11_verify_release.py` cross-checks model ↔ labels ↔ prototypes ↔ DB and runs
real predictions through the .mlpackage. Must print "All checks passed".

Bundle budget: model 57 MB (or ~20 palettized) + prototypes 6.2 + meta DB ~8
− 98 MB removed FeaturePrint index ≈ **net −27 to −65 MB** vs today.

### Suggested week

| Day | Work |
|---|---|
| 1 | Phase A + smoke test; start `--match` in a spare hour |
| 2 | Train v1 (after your current training frees the GPU), evaluate |
| 3 | Iterate if needed (min-images / epochs / backbone), export + index |
| 4 | Finish azbyka review + scrape, build meta DB, verify release |
| 5–6 | Swift integration (section 5) |
| 7 | Wild-photo testing (section 6), tune τ, ship |

## 5. Swift integration (reference implementation)

Files to add to the app target. Artifacts: drag
`IconClassifier.mlpackage` into Xcode (member of app target — Xcode compiles
it to .mlmodelc); copy `icon_prototypes.f32/.json` and `icon_meta.sqlite`
into `RussianOrthodoxReader/Resources/Icons/` (that folder is already a
bundled folder reference). Delete the three old `icon_feature_*` files.

### 5.1 `IconRecognizer.swift`

```swift
import Vision
import CoreML
import UIKit

struct IconMatch {
    let iconId: Int
    let name: String
    let score: Float          // softmax prob (classifier) or cosine (prototypes)
}

enum IconRecognitionResult {
    case recognized(IconMatch, alternatives: [IconMatch])
    case suggestions([IconMatch])   // below τ — show "возможно, это…"
    case unknown
}

final class IconRecognizer {
    static let shared = IconRecognizer()

    // From eval_report.md ("Recommended threshold") after training:
    private let softmaxThreshold: Float = 0.65      // TODO: value from 06_evaluate
    private let cosineThreshold: Float = 0.45       // tune on wild photos

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
```

### 5.2 `PrototypeIndex.swift`

```swift
import CoreML
import Accelerate

final class PrototypeIndex {
    private var vectors: [Float] = []      // rowCount × dim, L2-normalized rows
    private var subjects: [(iconId: Int, name: String)] = []
    private var dim = 0

    init() {
        guard let jsonURL = Bundle.main.url(forResource: "icon_prototypes",
                                            withExtension: "json",
                                            subdirectory: "Icons"),
              let f32URL = Bundle.main.url(forResource: "icon_prototypes",
                                           withExtension: "f32",
                                           subdirectory: "Icons"),
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
```

### 5.3 `IconMetaRepository.swift` — content lookup

Follow the `BibleSQLiteRepository` pattern (sqlite3 C API, read-only,
`Bundle.main.url(forResource: "icon_meta", withExtension: "sqlite",
subdirectory: "Icons")`). Queries:

```sql
SELECT name, category, feast_days_json, azbyka_url FROM subjects WHERE icon_id = ?;
SELECT life,    source FROM lives     WHERE icon_id = ?;   -- житие святого
SELECT history, source FROM histories WHERE icon_id = ?;   -- история иконы
SELECT kind, glas, body FROM prayers WHERE icon_id = ? ORDER BY position;
```

`lives` is keyed by subject, and every icon photo of the same saint maps to
the same subject — so the saint's житие is naturally *shared across all his
icons*, exactly as intended. Theotokos types get per-type `histories`.

### 5.4 UI wiring

- New screen «Распознать икону»: `PhotosPicker` +
  camera capture (`UIImagePickerController` wrapper or AVFoundation).
  Add `NSCameraUsageDescription` to Info.plist (Russian text) if using camera.
- Result view: name + confidence → sections «Житие» / «История иконы» /
  «Молитвы» (kind + глас headers), plus thumbnails from the existing
  `Thumbs/` folder and a link into the icon browser (icons.sqlite).
- `.suggestions` state: «Возможно, это:» list with top-5; `.unknown`:
  «Не удалось распознать. Попробуйте снять без бликов, ровно и ближе.»
- Entry points: a button on TodayView and/or the tab bar's long-press menu —
  your call; the service layer above doesn't constrain it.

## 6. Quality targets & the wild-photo test

Pravicon test-set numbers are necessary but not sufficient — the real test is
phone photos with glare and perspective:

1. Photograph 30–50 icons (home, church shop, church — where photography is
   appropriate) covering famous and mid-tier subjects.
2. Sort into `wild_test/<icon_id>/*.jpg` and run `06_evaluate.py` pointing
   `--checkpoint` at your model after replacing `work/splits/test.csv` rows —
   or simply drop them through the app and log results.
3. Acceptance for v1: **top-1 ≥ 75% on wild photos of classifier subjects,
   ≥ 90% of misses covered by the top-5 suggestions, < 10% confident-wrong**
   (that last one is what τ controls — raise τ if you see confident nonsense).

## 7. Data sources & licensing

- **pravicon.com** — images used only for local model training (not
  redistributed); thumbnails already ship in the app from your earlier work.
  Attribution row exists per subject (`pravicon_url`).
- **azbyka.ru** — жития/молитвы are traditional texts; the app already uses
  azbyka for the liturgical calendar. `source` columns + `azbyka_url` keep
  attribution; scraping is polite (1.5 s delay, resumable, identifying UA).
- Consider a «Источники» line in the icon detail screen: «Тексты: azbyka.ru;
  каталог икон: pravicon.com».

## 8. Risks & troubleshooting

| Symptom | Cause / fix |
|---|---|
| `pip install` fails on torch | You're on Python 3.14 (`python3` default). Use `/opt/homebrew/bin/python3.12 -m venv .venv` — already done |
| Training slow / GPU busy | Your other model is using MPS. Phases A and C are CPU/network-only — do them first; train later. Don't run two MPS trainings at once |
| MPS op error in training | Re-run with `PYTORCH_ENABLE_MPS_FALLBACK=1 .venv/bin/python 05_train.py …` (rare on this stack; smoke-tested clean) |
| Core ML conversion breaks after upgrading torch/coremltools | Stay on the pinned pair (2.5.1 / 8.1 — parity-verified). If you must upgrade, upgrade both and trust only a green parity check |
| Val accuracy great, wild photos poor | Domain gap: check τ, add your wild photos as extra *test* (never train on your only test set), consider more glare/perspective aug (`icon_dataset.py`) |
| One class eats another (confusion pairs in eval_report) | Usually near-identical iconography (e.g. two bishops). Options: merge subjects, add images, or accept — top-3 UI covers it |
| azbyka markup changes | `09 --probe` fails loudly; update the three selectors in `parse_page()` (documented in the script header) |
| App binary too big | `--palettize-bits 6` (57→~20 MB), and/or ship prototypes as FP16 (halves 6.2 MB; add a converter + change Swift reader to Float16) |

## 9. Roadmap after v1

1. **Feedback loop**: log (locally) photos where the user picked a suggestion
   over the top-1 → export → add to training set → retrain (`05 → 07 → 08`).
2. **Widen coverage**: `--min-images 15` (≈600 classes) once v1 metrics hold.
3. **Detection + crop** for iconostasis photos with many icons (YOLO-style
   detector in front of the classifier; or let the user crop manually — v1 UX).
4. **ArcFace margin** on the embedding head for sharper retrieval
   (`icon_model.py`, add margin to `NormLinear`) — only if prototype
   suggestions feel weak.
5. **OCR of inscriptions** (Church Slavonic) as a secondary signal — big
   accuracy unlock, big project.

## 10. Release checklist

- [ ] `04_make_splits.py` re-run with real `--min-images` (not smoke's 3 classes)
- [ ] `eval_report.md`: top-1 ≥ 85%, recommended τ copied into `IconRecognizer.swift`
- [ ] `07_export_coreml.py` printed **PARITY OK** for the exact file you ship
- [ ] `11_verify_release.py` — all green
- [ ] Old `icon_feature_*` files deleted from `Resources/Icons/`
- [ ] Wild-photo pass (section 6) done
- [ ] «Источники» attribution visible in UI
- [ ] Version bump in SettingsView About (v1.2?)
