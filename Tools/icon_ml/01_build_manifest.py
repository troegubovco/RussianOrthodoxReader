#!/usr/bin/env python3
"""Step 01 — Build the image manifest from pravicon scrape data.

Maps every downloaded image file to its subject (pravicon icon_id), and flags
images that are referenced by MORE THAN ONE subject — those are ambiguous
labels (group icons, misfiled photos) and are excluded from training later.

Usage:
    .venv/bin/python 01_build_manifest.py
Output:
    work/manifest.csv   (image_id, icon_id, category, name, relpath, ambiguous)
"""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict

from common import (DETAILS_JSON, IMAGES_DIR, MANIFEST_CSV, ManifestRow,
                    write_manifest)

THUMB_ID_RE = re.compile(r"/(\d+)_t\.jpg$")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--details", default=str(DETAILS_JSON))
    parser.add_argument("--output", default=str(MANIFEST_CSV))
    args = parser.parse_args()

    with open(args.details, encoding="utf-8") as f:
        details = json.load(f)
    print(f"Loaded {len(details)} subjects from {args.details}")

    # image_id -> set of icon_ids that reference it
    image_subjects: dict[int, set[int]] = defaultdict(set)
    subject_images: dict[int, list[tuple[int, str]]] = {}  # icon_id -> [(image_id, relpath)]
    meta: dict[int, tuple[str, str]] = {}                   # icon_id -> (category, name)

    n_missing = 0
    n_errors = 0
    for entry in details:
        icon_id = entry.get("icon_id")
        if not icon_id or entry.get("error"):
            n_errors += 1
            continue
        category = entry.get("category", "")
        name = entry.get("name", "")
        meta[icon_id] = (category, name)
        found: list[tuple[int, str]] = []
        for thumb in entry.get("thumbnails", []):
            m = THUMB_ID_RE.search(thumb)
            if not m:
                continue
            image_id = int(m.group(1))
            relpath = f"full/{category}/{image_id}.jpg"
            if (IMAGES_DIR / category / f"{image_id}.jpg").exists():
                found.append((image_id, relpath))
                image_subjects[image_id].add(icon_id)
            else:
                n_missing += 1
        subject_images[icon_id] = found

    rows: list[ManifestRow] = []
    for icon_id, images in subject_images.items():
        category, name = meta[icon_id]
        for image_id, relpath in images:
            rows.append(ManifestRow(
                image_id=image_id, icon_id=icon_id, category=category,
                name=name, relpath=relpath,
                ambiguous=1 if len(image_subjects[image_id]) > 1 else 0,
            ))

    rows.sort(key=lambda r: (r.icon_id, r.image_id))
    write_manifest(MANIFEST_CSV if args.output == str(MANIFEST_CSV) else __import__("pathlib").Path(args.output), rows)

    n_ambiguous = sum(1 for r in rows if r.ambiguous)
    n_subjects = len({r.icon_id for r in rows})
    print(f"Manifest: {len(rows)} image rows, {n_subjects} subjects")
    print(f"  ambiguous (multi-subject) rows: {n_ambiguous}")
    print(f"  thumbnails without local file:  {n_missing}")
    print(f"  subject entries skipped (errors): {n_errors}")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
