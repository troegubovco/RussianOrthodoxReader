#!/usr/bin/env python3
"""Step 02 — Pre-resize images into work/cache512 for fast training.

Full-size pravicon JPEGs can be several megapixels; decoding them dominates
training time. This writes max-side-512 JPEG copies once; every later step
(dedupe, training, indexing) automatically prefers the cache via
common.resolve_image_path(). Safe to interrupt and re-run (resumes).

Usage:
    .venv/bin/python 02_make_cache.py [--max-side 512] [--workers 8]
"""
from __future__ import annotations

import argparse
from multiprocessing import Pool
from pathlib import Path

from PIL import Image, ImageFile
from tqdm import tqdm

from common import CACHE_DIR, DATA_DIR, MANIFEST_CSV, read_manifest

ImageFile.LOAD_TRUNCATED_IMAGES = True

_max_side = 512


def _init(max_side: int):
    global _max_side
    _max_side = max_side


def _process(relpath: str) -> str | None:
    src = DATA_DIR / "pravicon_images" / relpath
    rel_cache = relpath[len("full/"):] if relpath.startswith("full/") else relpath
    dst = CACHE_DIR / rel_cache
    if dst.exists():
        return None
    try:
        with Image.open(src) as im:
            im.draft("RGB", (_max_side, _max_side))  # fast JPEG downscale decode
            im = im.convert("RGB")
            im.thumbnail((_max_side, _max_side), Image.LANCZOS)
            dst.parent.mkdir(parents=True, exist_ok=True)
            im.save(dst, "JPEG", quality=87)
        return None
    except Exception as e:  # corrupt file — report, don't crash the pool
        return f"{relpath}: {e}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(MANIFEST_CSV))
    parser.add_argument("--max-side", type=int, default=512)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    rows = read_manifest(Path(args.manifest))
    relpaths = sorted({r.relpath for r in rows})
    print(f"{len(relpaths)} unique images to cache at max side {args.max_side}px")

    errors = []
    with Pool(args.workers, initializer=_init, initargs=(args.max_side,)) as pool:
        for err in tqdm(pool.imap_unordered(_process, relpaths, chunksize=64),
                        total=len(relpaths), unit="img"):
            if err:
                errors.append(err)

    if errors:
        print(f"\n{len(errors)} files failed to decode:")
        for e in errors[:20]:
            print("  ", e)
    print(f"Cache ready at {CACHE_DIR}")


if __name__ == "__main__":
    main()
