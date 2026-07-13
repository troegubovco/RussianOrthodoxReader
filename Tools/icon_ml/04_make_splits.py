#!/usr/bin/env python3
"""Step 04 — Select classifier classes and build train/val/test/OOD splits.

Classes = subjects with at least --min-images deduplicated, unambiguous
images (default 20 — about 420 classes covering the most-venerated icons).
Everything below the threshold plus the blacklisted catch-all galleries
becomes the OOD (out-of-distribution) pool used to calibrate the
"не распознано" rejection threshold.

Usage:
    .venv/bin/python 04_make_splits.py [--min-images 20] [--max-train-per-class 60]
Output:
    work/labels.json, work/splits/{train,val,test,ood}.csv
"""
from __future__ import annotations

import argparse
import csv
import datetime
import json
import random
from collections import defaultdict
from pathlib import Path

from common import (BLACKLIST_RE, LABELS_JSON, MANIFEST_DEDUP_CSV, SPLITS_DIR,
                    read_manifest)


def write_split(path: Path, rows: list[tuple[str, int]]):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["relpath", "label"])
        w.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(MANIFEST_DEDUP_CSV))
    parser.add_argument("--min-images", type=int, default=20)
    parser.add_argument("--max-train-per-class", type=int, default=60)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--limit-classes", type=int, default=0,
                        help="debug/smoke: keep only the N largest classes")
    parser.add_argument("--include-ids", type=str, default="",
                        help="debug/smoke: comma-separated icon_ids to use as the only classes")
    args = parser.parse_args()

    rows = read_manifest(Path(args.manifest))

    by_subject: dict[int, list] = defaultdict(list)
    ood_pool: list[tuple[str, int]] = []
    meta: dict[int, tuple[str, str]] = {}
    for r in rows:
        meta[r.icon_id] = (r.category, r.name)
        if BLACKLIST_RE.search(r.name):
            ood_pool.append((r.relpath, -1))
            continue
        if r.ambiguous:
            continue
        by_subject[r.icon_id].append(r)

    include_ids = {int(x) for x in args.include_ids.split(",") if x.strip()}
    eligible = {sid: imgs for sid, imgs in by_subject.items()
                if len(imgs) >= args.min_images}
    if include_ids:
        eligible = {sid: imgs for sid, imgs in by_subject.items() if sid in include_ids}
    elif args.limit_classes:
        biggest = sorted(eligible, key=lambda s: -len(eligible[s]))[:args.limit_classes]
        eligible = {sid: eligible[sid] for sid in biggest}

    # Small subjects feed the OOD pool (one image each, they're unseen classes).
    for sid, imgs in by_subject.items():
        if sid not in eligible and 3 <= len(imgs):
            ood_pool.append((imgs[0].relpath, -1))

    classes = sorted(eligible.keys())
    train, val, test = [], [], []
    labels_meta = []
    for index, sid in enumerate(classes):
        imgs = sorted(eligible[sid], key=lambda r: r.image_id)
        rng = random.Random(args.seed * 31 + sid)
        rng.shuffle(imgs)
        n = len(imgs)
        n_test = max(3, min(6, n // 10)) if n >= 12 else max(1, n // 6)
        n_val = max(2, min(5, n // 12)) if n >= 12 else max(1, n // 6)
        test_rows = imgs[:n_test]
        val_rows = imgs[n_test:n_test + n_val]
        train_rows = imgs[n_test + n_val:][:args.max_train_per_class]
        test += [(r.relpath, index) for r in test_rows]
        val += [(r.relpath, index) for r in val_rows]
        train += [(r.relpath, index) for r in train_rows]
        category, name = meta[sid]
        labels_meta.append({
            "index": index, "icon_id": sid, "name": name, "category": category,
            "n_train": len(train_rows), "n_val": len(val_rows), "n_test": len(test_rows),
        })

    rng = random.Random(args.seed)
    rng.shuffle(ood_pool)
    ood = ood_pool[:1000]

    write_split(SPLITS_DIR / "train.csv", train)
    write_split(SPLITS_DIR / "val.csv", val)
    write_split(SPLITS_DIR / "test.csv", test)
    write_split(SPLITS_DIR / "ood.csv", ood)

    LABELS_JSON.parent.mkdir(parents=True, exist_ok=True)
    with open(LABELS_JSON, "w", encoding="utf-8") as f:
        json.dump({
            "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "min_images": args.min_images,
            "num_classes": len(classes),
            "classes": labels_meta,
        }, f, ensure_ascii=False, indent=1)

    by_cat = defaultdict(int)
    for m in labels_meta:
        by_cat[m["category"]] += 1
    print(f"Classes: {len(classes)}  "
          f"({', '.join(f'{k}={v}' for k, v in sorted(by_cat.items()))})")
    print(f"Split sizes: train={len(train)} val={len(val)} test={len(test)} ood={len(ood)}")
    print(f"Wrote {SPLITS_DIR}/ and {LABELS_JSON}")


if __name__ == "__main__":
    main()
