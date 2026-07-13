#!/usr/bin/env python3
"""Step 11 — Cross-check all release artifacts before bundling into the app.

Verifies that the Core ML model, the prototype index, labels.json and
icon_meta.sqlite all agree with each other, and runs two real predictions
through the .mlpackage.

Usage:
    .venv/bin/python 11_verify_release.py \
        --mlpackage work/export/IconClassifier.mlpackage
"""
from __future__ import annotations

import argparse
import csv
import json
import sqlite3
import sys
from pathlib import Path

import numpy as np
from PIL import Image

from common import (INDEX_DIR, LABELS_JSON, META_DB, SPLITS_DIR,
                    resolve_image_path)

FAIL = []


def check(cond: bool, msg: str):
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond:
        FAIL.append(msg)


def dir_size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mlpackage", default="work/export/IconClassifier.mlpackage")
    parser.add_argument("--index-dir", default=str(INDEX_DIR))
    parser.add_argument("--meta-db", default=str(META_DB))
    args = parser.parse_args()

    with open(LABELS_JSON, encoding="utf-8") as f:
        labels_doc = json.load(f)
    classes = labels_doc["classes"]
    num_classes = labels_doc["num_classes"]
    print(f"labels.json: {num_classes} classes")

    # --- Prototype index ---
    print("Prototype index:")
    idx_json = Path(args.index_dir) / "icon_prototypes.json"
    idx_f32 = Path(args.index_dir) / "icon_prototypes.f32"
    check(idx_json.exists() and idx_f32.exists(), "index files exist")
    proto_subjects = set()
    dim = 0
    if idx_json.exists():
        with open(idx_json, encoding="utf-8") as f:
            idx = json.load(f)
        dim = idx["dimension"]
        proto_subjects = {s["icon_id"] for s in idx["subjects"]}
        expected = idx["rowCount"] * dim * 4
        check(idx_f32.stat().st_size == expected,
              f"f32 size matches rowCount×dim×4 ({idx['rowCount']}×{dim})")
        vecs = np.fromfile(idx_f32, dtype=np.float32).reshape(idx["rowCount"], dim)
        norms = np.linalg.norm(vecs, axis=1)
        check(bool(np.all(np.abs(norms - 1.0) < 1e-2)), "prototype rows are L2-normalized")
        missing = [c["icon_id"] for c in classes if c["icon_id"] not in proto_subjects]
        check(not missing, f"all classifier classes have prototypes "
                           f"({len(missing)} missing)")

    # --- Metadata DB ---
    print("icon_meta.sqlite:")
    db = Path(args.meta_db)
    check(db.exists(), "db exists")
    if db.exists():
        conn = sqlite3.connect(db)
        rows = dict(conn.execute(
            "SELECT icon_id, label_index FROM subjects WHERE label_index IS NOT NULL"))
        check(len(rows) == num_classes, f"db has {len(rows)} labeled subjects "
                                        f"(expected {num_classes})")
        mismatched = [c for c in classes if rows.get(c["icon_id"]) != c["index"]]
        check(not mismatched, f"label_index values agree ({len(mismatched)} mismatched)")
        n_text = conn.execute(
            "SELECT COUNT(*) FROM subjects s WHERE s.label_index IS NOT NULL AND "
            "(EXISTS(SELECT 1 FROM lives WHERE icon_id=s.icon_id) OR "
            " EXISTS(SELECT 1 FROM histories WHERE icon_id=s.icon_id))").fetchone()[0]
        n_pray = conn.execute(
            "SELECT COUNT(DISTINCT icon_id) FROM prayers WHERE icon_id IN "
            "(SELECT icon_id FROM subjects WHERE label_index IS NOT NULL)").fetchone()[0]
        print(f"       coverage: {n_text}/{num_classes} classes with text, "
              f"{n_pray}/{num_classes} with prayers")
        conn.close()

    # --- Core ML model ---
    print("Core ML model:")
    pkg = Path(args.mlpackage)
    check(pkg.exists(), f"{pkg} exists")
    if pkg.exists():
        import coremltools as ct
        mlmodel = ct.models.MLModel(str(pkg))
        meta_labels = json.loads(mlmodel.user_defined_metadata.get("labels_json", "[]"))
        check(len(meta_labels) == num_classes,
              f"embedded labels ({len(meta_labels)}) match labels.json")
        img_size = int(mlmodel.user_defined_metadata.get("img_size", "256"))

        test_csv = SPLITS_DIR / "test.csv"
        if test_csv.exists():
            with open(test_csv, newline="", encoding="utf-8") as f:
                samples = [(r["relpath"], int(r["label"]))
                           for r in csv.DictReader(f)][:2]
            for relpath, label in samples:
                with Image.open(resolve_image_path(relpath)) as im:
                    img = im.convert("RGB")
                resize = int(img_size * 292 / 256)
                s = resize / min(img.size)
                img = img.resize((round(img.width * s), round(img.height * s)),
                                 Image.BICUBIC)
                left, top = (img.width - img_size) // 2, (img.height - img_size) // 2
                img = img.crop((left, top, left + img_size, top + img_size))
                out = mlmodel.predict({"image": img})
                probs = np.asarray(out["probabilities"]).reshape(-1)
                emb = np.asarray(out["embedding"]).reshape(-1)
                check(len(probs) == num_classes, "probabilities length == num_classes")
                check(dim == 0 or len(emb) == dim,
                      "embedding length matches prototype dimension")
                top = int(probs.argmax())
                name = next(c["name"] for c in classes if c["index"] == top)
                truth = next(c["name"] for c in classes if c["index"] == label)
                print(f"       sample: true='{truth[:40]}' -> "
                      f"pred='{name[:40]}' p={probs[top]:.2f}")

    # --- Size budget ---
    print("Bundle size:")
    for p in [Path(args.mlpackage), idx_f32, idx_json, db]:
        if p.exists():
            print(f"       {dir_size(p) / 1e6:8.1f} MB  {p.name}")

    if FAIL:
        print(f"\n{len(FAIL)} CHECKS FAILED")
        sys.exit(1)
    print("\nAll checks passed — artifacts are consistent.")


if __name__ == "__main__":
    main()
