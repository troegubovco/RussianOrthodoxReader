#!/usr/bin/env python3
"""Step 07 — Export the trained model to Core ML (.mlpackage).

Produces a dual-output ML Program:
  - `probabilities` (num_classes) — softmax over the curated classes
  - `embedding` (embed_dim, L2-normalized) — for prototype k-NN retrieval
Input is a 256×256 RGB image; pixel scaling and ImageNet normalization are
folded into the model, so Swift passes a plain CVPixelBuffer.

Class labels (icon_id + name per index) are embedded in the model's
user-defined metadata under key `labels_json`.

Ends with a torch↔coreml parity check on real images — do not ship a model
whose parity check failed.

Usage:
    .venv/bin/python 07_export_coreml.py --checkpoint work/runs/v1/best.pt
    .venv/bin/python 07_export_coreml.py --checkpoint ... --palettize-bits 6
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image

from common import EXPORT_DIR, SPLITS_DIR, resolve_image_path
from icon_model import ExportNet, load_checkpoint


def eval_pil(relpath: str, img_size: int) -> Image.Image:
    with Image.open(resolve_image_path(relpath)) as im:
        img = im.convert("RGB")
    resize = int(img_size * 292 / 256)
    w, h = img.size
    scale = resize / min(w, h)
    img = img.resize((round(w * scale), round(h * scale)), Image.BICUBIC)
    left = (img.width - img_size) // 2
    top = (img.height - img_size) // 2
    return img.crop((left, top, left + img_size, top + img_size))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--out", default="")
    parser.add_argument("--palettize-bits", type=int, default=0,
                        help="0=off; 6 ≈ 3x smaller with minimal accuracy loss")
    parser.add_argument("--samples", type=int, default=3)
    args = parser.parse_args()

    model, ckpt = load_checkpoint(Path(args.checkpoint), "cpu")
    cfg = ckpt["config"]
    img_size = cfg["img_size"]
    export_net = ExportNet(model).eval()

    example = torch.rand(1, 3, img_size, img_size)
    traced = torch.jit.trace(export_net, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, img_size, img_size),
                             scale=1.0 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="probabilities"), ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )

    labels_compact = [{"i": c["index"], "id": c["icon_id"], "n": c["name"],
                       "c": c["category"]} for c in cfg["labels"]]
    mlmodel.user_defined_metadata["labels_json"] = json.dumps(
        labels_compact, ensure_ascii=False)
    mlmodel.user_defined_metadata["model_name"] = cfg["model_name"]
    mlmodel.user_defined_metadata["img_size"] = str(img_size)
    mlmodel.short_description = (
        f"Orthodox icon classifier ({cfg['num_classes']} subjects) + embedding")

    out = Path(args.out) if args.out else EXPORT_DIR / "IconClassifier.mlpackage"
    out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out))
    print(f"Saved {out}")

    if args.palettize_bits:
        from coremltools.optimize.coreml import (OpPalettizerConfig,
                                                 OptimizationConfig,
                                                 palettize_weights)
        opt_cfg = OptimizationConfig(global_config=OpPalettizerConfig(
            mode="kmeans", nbits=args.palettize_bits))
        mlmodel_pal = palettize_weights(mlmodel, opt_cfg)
        out_pal = out.with_name(out.stem + f"_pal{args.palettize_bits}.mlpackage")
        mlmodel_pal.save(str(out_pal))
        print(f"Saved palettized {out_pal}")

    # --- Parity check: torch vs Core ML on real images ---
    test_csv = SPLITS_DIR / "test.csv"
    rows = []
    if test_csv.exists():
        with open(test_csv, newline="", encoding="utf-8") as f:
            rows = [r["relpath"] for r in csv.DictReader(f)][:args.samples]
    if not rows:
        print("No test split found — skipping parity check")
        return

    loaded = ct.models.MLModel(str(out))
    max_diff, top1_match = 0.0, True
    for relpath in rows:
        pil = eval_pil(relpath, img_size)
        x = torch.from_numpy(np.asarray(pil).astype(np.float32) / 255.0)
        x = x.permute(2, 0, 1).unsqueeze(0)
        with torch.no_grad():
            probs_t, _ = export_net(x)
        probs_t = probs_t[0].numpy()
        pred_ml = loaded.predict({"image": pil})
        probs_c = np.asarray(pred_ml["probabilities"]).reshape(-1)
        diff = float(np.abs(probs_t - probs_c).max())
        max_diff = max(max_diff, diff)
        same = int(probs_t.argmax()) == int(probs_c.argmax())
        top1_match &= same
        print(f"  parity {relpath}: top1 torch={probs_t.argmax()} "
              f"coreml={probs_c.argmax()} same={same} maxΔ={diff:.4f}")

    if top1_match and max_diff < 0.02:
        print(f"PARITY OK (max prob diff {max_diff:.4f})")
    else:
        raise SystemExit(f"PARITY FAILED: top1_match={top1_match}, maxΔ={max_diff:.4f} — "
                         "do not ship this model; check torch/coremltools versions")


if __name__ == "__main__":
    main()
