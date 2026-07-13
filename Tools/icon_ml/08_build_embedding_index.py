#!/usr/bin/env python3
"""Step 08 — Build the per-subject prototype embedding index.

Runs the trained model over ALL deduplicated, unambiguous images (all ~3,150
subjects, not just classifier classes), averages the L2-normalized embeddings
per subject, and writes:

    work/index/icon_prototypes.f32   float32 rows, one per subject, L2-normalized
    work/index/icon_prototypes.json  ordering + names + dims (Swift reads both)

This replaces the old 98 MB Vision FeaturePrint index with a ~6 MB index in a
space actually trained on icons. Cosine similarity = plain dot product.

Usage:
    .venv/bin/python 08_build_embedding_index.py --checkpoint work/runs/v1/best.pt
"""
from __future__ import annotations

import argparse
import datetime
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader
from tqdm import tqdm

from common import BLACKLIST_RE, INDEX_DIR, MANIFEST_DEDUP_CSV, read_manifest
from icon_dataset import IconDataset
from icon_model import load_checkpoint, pick_device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--manifest", default=str(MANIFEST_DEDUP_CSV))
    parser.add_argument("--device", default="auto")
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--max-per-subject", type=int, default=40,
                        help="cap images per subject for the prototype mean")
    parser.add_argument("--out-dir", default=str(INDEX_DIR))
    args = parser.parse_args()

    device = pick_device(args.device)
    model, ckpt = load_checkpoint(Path(args.checkpoint), device)
    cfg = ckpt["config"]
    embed_dim = cfg["embed_dim"]

    rows_all = read_manifest(Path(args.manifest))
    by_subject = defaultdict(list)
    meta = {}
    for r in rows_all:
        if r.ambiguous or BLACKLIST_RE.search(r.name):
            continue
        by_subject[r.icon_id].append(r)
        meta[r.icon_id] = (r.category, r.name)

    subject_ids = sorted(by_subject.keys())
    ordinal = {sid: i for i, sid in enumerate(subject_ids)}
    ds_rows = []
    for sid in subject_ids:
        for r in sorted(by_subject[sid], key=lambda r: r.image_id)[:args.max_per_subject]:
            ds_rows.append((r.relpath, ordinal[sid]))

    print(f"{len(subject_ids)} subjects, {len(ds_rows)} images, device={device}")
    ds = IconDataset(ds_rows, cfg["img_size"], train=False)
    loader = DataLoader(ds, batch_size=args.batch_size, num_workers=args.workers)

    sums = np.zeros((len(subject_ids), embed_dim), dtype=np.float64)
    counts = np.zeros(len(subject_ids), dtype=np.int64)
    with torch.no_grad():
        for x, y in tqdm(loader, unit="batch"):
            _, emb = model(x.to(device))
            emb = emb.cpu().numpy()
            for i, ord_idx in enumerate(y.tolist()):
                sums[ord_idx] += emb[i]
                counts[ord_idx] += 1

    protos = sums / np.maximum(counts, 1)[:, None]
    norms = np.linalg.norm(protos, axis=1, keepdims=True)
    protos = (protos / np.maximum(norms, 1e-8)).astype(np.float32)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    protos.tofile(out_dir / "icon_prototypes.f32")
    manifest = {
        "version": "2",
        "dimension": embed_dim,
        "rowCount": len(subject_ids),
        "metric": "cosine",
        "modelName": cfg["model_name"],
        "checkpoint": str(args.checkpoint),
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "subjects": [
            {"icon_id": sid, "name": meta[sid][1], "category": meta[sid][0],
             "images_used": int(counts[ordinal[sid]])}
            for sid in subject_ids
        ],
    }
    with open(out_dir / "icon_prototypes.json", "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)

    size_mb = (out_dir / "icon_prototypes.f32").stat().st_size / 1e6
    print(f"Wrote {out_dir}/icon_prototypes.f32 ({size_mb:.1f} MB, "
          f"{len(subject_ids)}×{embed_dim}) and icon_prototypes.json")


if __name__ == "__main__":
    main()
