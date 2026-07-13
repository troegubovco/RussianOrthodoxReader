#!/usr/bin/env python3
"""Step 03 — Perceptual-hash deduplication.

Pravicon galleries contain many re-photographs and re-scans of the same
physical icon. If near-duplicates land in both train and test, accuracy is
inflated and meaningless — so dedupe MUST happen before splitting.

Two passes:
  1. Within a subject: drop images whose pHash is within --threshold Hamming
     distance of an already-kept image of that subject.
  2. Across subjects: images that are near-identical (<= --cross-threshold)
     but filed under DIFFERENT subjects get flagged ambiguous (excluded from
     training/eval and prototypes — the label is untrustworthy).

Usage:
    .venv/bin/python 03_dedupe.py [--threshold 6] [--cross-threshold 4] [--workers 8]
Output:
    work/manifest_dedup.csv, work/dedupe_report.txt
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from multiprocessing import Pool
from pathlib import Path

import imagehash
from PIL import Image, ImageFile
from tqdm import tqdm

from common import (MANIFEST_CSV, MANIFEST_DEDUP_CSV, WORK_DIR, ManifestRow,
                    read_manifest, resolve_image_path, write_manifest)

ImageFile.LOAD_TRUNCATED_IMAGES = True


def _hash_one(relpath: str) -> tuple[str, int | None]:
    try:
        with Image.open(resolve_image_path(relpath)) as im:
            im.draft("RGB", (256, 256))
            h = imagehash.phash(im.convert("RGB"))
        return relpath, int(str(h), 16)
    except Exception:
        return relpath, None


def hamming(a: int, b: int) -> int:
    return (a ^ b).bit_count()


# 5 bands over 64 bits: any pair with Hamming distance <= 4 shares at least
# one identical band (pigeonhole), so band buckets give candidate pairs.
_BANDS = [(0, 13), (13, 13), (26, 13), (39, 13), (52, 12)]


def band_keys(h: int):
    for i, (shift, width) in enumerate(_BANDS):
        yield (i, (h >> shift) & ((1 << width) - 1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(MANIFEST_CSV))
    parser.add_argument("--output", default=str(MANIFEST_DEDUP_CSV))
    parser.add_argument("--threshold", type=int, default=6,
                        help="within-subject Hamming distance to treat as duplicate")
    parser.add_argument("--cross-threshold", type=int, default=4,
                        help="cross-subject distance to flag as ambiguous")
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--include-ids", type=str, default="",
                        help="debug/smoke: only process these comma-separated icon_ids")
    args = parser.parse_args()

    rows = read_manifest(Path(args.manifest))
    if args.include_ids:
        keep = {int(x) for x in args.include_ids.split(",") if x.strip()}
        rows = [r for r in rows if r.icon_id in keep]
    relpaths = sorted({r.relpath for r in rows})
    print(f"Hashing {len(relpaths)} images ...")

    hashes: dict[str, int] = {}
    failed: list[str] = []
    with Pool(args.workers) as pool:
        for relpath, h in tqdm(pool.imap_unordered(_hash_one, relpaths, chunksize=64),
                               total=len(relpaths), unit="img"):
            if h is None:
                failed.append(relpath)
            else:
                hashes[relpath] = h

    # Pass 1: within-subject dedupe (greedy keep-first by image_id order).
    by_subject: dict[int, list[ManifestRow]] = defaultdict(list)
    for r in rows:
        if r.relpath in hashes:
            by_subject[r.icon_id].append(r)

    kept: list[ManifestRow] = []
    dropped: list[tuple[ManifestRow, int]] = []
    for icon_id, subject_rows in by_subject.items():
        subject_rows.sort(key=lambda r: r.image_id)
        kept_hashes: list[int] = []
        for r in subject_rows:
            h = hashes[r.relpath]
            dup_of = next((kh for kh in kept_hashes if hamming(h, kh) <= args.threshold), None)
            if dup_of is None:
                kept_hashes.append(h)
                kept.append(r)
            else:
                dropped.append((r, dup_of))

    # Pass 2: cross-subject near-duplicates -> ambiguous.
    buckets: dict[tuple[int, int], list[int]] = defaultdict(list)
    kept_hash_list = [(i, hashes[r.relpath]) for i, r in enumerate(kept)]
    for i, h in kept_hash_list:
        for key in band_keys(h):
            buckets[key].append(i)

    ambiguous_idx: set[int] = set()
    checked: set[tuple[int, int]] = set()
    for members in buckets.values():
        if len(members) < 2:
            continue
        for ai in range(len(members)):
            for bi in range(ai + 1, len(members)):
                a, b = members[ai], members[bi]
                if (a, b) in checked:
                    continue
                checked.add((a, b))
                ra, rb = kept[a], kept[b]
                if ra.icon_id == rb.icon_id:
                    continue
                if hamming(hashes[ra.relpath], hashes[rb.relpath]) <= args.cross_threshold:
                    ambiguous_idx.add(a)
                    ambiguous_idx.add(b)

    n_cross = 0
    for i in ambiguous_idx:
        if not kept[i].ambiguous:
            kept[i].ambiguous = 1
            n_cross += 1

    write_manifest(Path(args.output), kept)

    report = WORK_DIR / "dedupe_report.txt"
    with open(report, "w", encoding="utf-8") as f:
        f.write(f"input rows:            {len(rows)}\n")
        f.write(f"hash failures:         {len(failed)}\n")
        f.write(f"within-subject dropped:{len(dropped)}\n")
        f.write(f"cross-subject flagged: {n_cross}\n")
        f.write(f"kept rows:             {len(kept)}\n\n")
        for r, _ in dropped[:500]:
            f.write(f"drop {r.relpath} (subject {r.icon_id} {r.name})\n")

    print(f"Kept {len(kept)} rows "
          f"(dropped {len(dropped)} within-subject dups, "
          f"flagged {n_cross} cross-subject ambiguous, {len(failed)} unreadable)")
    print(f"Wrote {args.output} and {report}")


if __name__ == "__main__":
    main()
