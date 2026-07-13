# Icon ML pipeline — распознавание икон on-device

Trains a Core ML model that identifies the subject of an Orthodox icon photo
(which saint / which Theotokos type / which feast), plus builds the metadata
database (saint lives, icon histories, prayers) shown after recognition.

**Read [PLAN.md](PLAN.md) first** — it explains the architecture, every
decision, expected numbers, and the Swift integration. This file is just the
command reference.

## One-time setup

```bash
cd Tools/icon_ml
/opt/homebrew/bin/python3.12 -m venv .venv       # needs Python 3.12 (NOT 3.14)
.venv/bin/pip install -U pip
.venv/bin/pip install -r requirements.txt
```

## Full pipeline, in order

```bash
cd Tools/icon_ml

# ---- Data (CPU, ~15 min total) ----
.venv/bin/python 01_build_manifest.py            # ~5 s   -> work/manifest.csv
.venv/bin/python 02_make_cache.py                # ~5 min -> work/cache512/ (~1.5 GB)
.venv/bin/python 03_dedupe.py                    # ~3 min -> work/manifest_dedup.csv
.venv/bin/python 04_make_splits.py --min-images 20   # ~5 s -> work/splits/, work/labels.json

# ---- Model (MPS — run when your other training is done) ----
.venv/bin/python 05_train.py --run-name v1       # ~1-2 min/epoch, 30 epochs
.venv/bin/python 06_evaluate.py --checkpoint work/runs/v1/best.pt
                                                 # -> work/runs/v1/eval_report.md
.venv/bin/python 07_export_coreml.py --checkpoint work/runs/v1/best.pt
                                                 # -> work/export/IconClassifier.mlpackage
.venv/bin/python 08_build_embedding_index.py --checkpoint work/runs/v1/best.pt
                                                 # -> work/index/icon_prototypes.{f32,json}

# ---- Content (network: azbyka.ru, polite 1.5 s/req) ----
.venv/bin/python 09_scrape_azbyka.py --probe     # self-test, 2 requests
.venv/bin/python 09_scrape_azbyka.py --match     # ~20-40 min, resumable
#   -> review work/azbyka_match.csv: fix rows with status check/notfound
#      (set url + status=manual), then:
.venv/bin/python 09_scrape_azbyka.py --scrape    # ~15 min, resumable
.venv/bin/python 10_build_meta_db.py             # -> work/icon_meta.sqlite

# ---- Release ----
.venv/bin/python 11_verify_release.py --mlpackage work/export/IconClassifier.mlpackage
```

## What goes into the app

| Artifact | Destination |
|---|---|
| `work/export/IconClassifier.mlpackage` | drag into Xcode project (target member) |
| `work/index/icon_prototypes.f32` + `.json` | `RussianOrthodoxReader/Resources/Icons/` |
| `work/icon_meta.sqlite` | `RussianOrthodoxReader/Resources/Icons/` |

Then DELETE the old FeaturePrint index from `Resources/Icons/`
(`icon_feature_vectors.f32`, `icon_feature_norms.f32`,
`icon_feature_manifest.json` — ~98 MB) — the prototype index replaces it.

## Iterating

- More classes: `04_make_splits.py --min-images 15` (≈600 classes) or `10`
  (≈960), then retrain. Quality per class drops as the tail grows — check
  `eval_report.md` before shipping.
- Different backbone: `05_train.py --model tf_efficientnetv2_s.in21k_ft_in1k --img-size 288`
- Smaller model file: `07_export_coreml.py --palettize-bits 6` (~3× smaller).
- Resume interrupted training: `05_train.py --run-name v1 --resume work/runs/v1/last.pt`

## Smoke test (verifies the whole chain in ~5 min, CPU-only)

Uses 3 famous subjects: 137 Казанская, 2868 Сергий Радонежский, 2946 Спиридон
Тримифунтский. Safe to run while another model is training (CPU-only, tiny).

```bash
.venv/bin/python 01_build_manifest.py
.venv/bin/python 03_dedupe.py --include-ids 137,2868,2946 --output work/manifest_smoke_dedup.csv
.venv/bin/python 04_make_splits.py --manifest work/manifest_smoke_dedup.csv --include-ids 137,2868,2946
.venv/bin/python 05_train.py --run-name smoke --device cpu --epochs 2 --freeze-epochs 1 \
    --limit-per-class 10 --batch-size 8 --workers 2 --patience 0
.venv/bin/python 07_export_coreml.py --checkpoint work/runs/smoke/best.pt --samples 2
.venv/bin/python 08_build_embedding_index.py --checkpoint work/runs/smoke/best.pt \
    --manifest work/manifest_smoke_dedup.csv --device cpu --workers 2
.venv/bin/python 09_scrape_azbyka.py --probe
.venv/bin/python 10_build_meta_db.py
.venv/bin/python 11_verify_release.py
```

This exact sequence was run and passed on 2026-07-01 (M5 Pro, macOS 26.5,
Python 3.12.12, torch 2.5.1, coremltools 8.1): Core ML parity maxΔ=0.0004,
all release checks green. IMPORTANT: after the smoke test, delete work/labels.json
and work/splits (or just re-run 03+04 for real) before real training.
