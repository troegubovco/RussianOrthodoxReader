#!/usr/bin/env python3
"""Step 11 — Pack reference thumbnails into icon_meta.sqlite and clean text data.

Idempotent post-processing step, run AFTER 10_build_meta_db.py. Paths are
relative to the repo root (run from there).

What it does:
  1. thumbs table       — one reference JPEG BLOB per subject, generated from
                           the local full-resolution pravicon corpus (never
                           upscaled), long edge 192px / quality 62.
  2. prayers.translation — new column; dedupes the Church-Slavonic body text
                           that shipped doubled (B3) and splits out the
                           "Перевод:" suffix into its own column.
  3. lives / histories   — whitespace / stray-newline cleanup.
  4. meta rows recording the thumbnail parameters, then VACUUM + journal
                           cleanup so the bundled DB never carries a
                           dangling -wal/-shm sidecar file.

`RussianOrthodoxReader/Resources/Icons/icons.sqlite` is opened READ-ONLY and
is never written to — it's excluded from the app bundle and only used here
to resolve (category, representative_image_id) per icon.

Usage:
    python3 Tools/icon_ml/11_pack_thumbs_and_clean.py
"""
from __future__ import annotations

import os
import re
import sqlite3
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageOps

META = "RussianOrthodoxReader/Resources/IconML/icon_meta.sqlite"
ICONS = "RussianOrthodoxReader/Resources/Icons/icons.sqlite"  # read-only
FULL = "Tools/data/pravicon_images/full/{category}/{image_id}.jpg"
FALLBACK = "RussianOrthodoxReader/Resources/Icons/Thumbs/{icon_id}.jpg"
THUMB_LONG_EDGE = 192
THUMB_QUALITY = 62

THUMBS_SCHEMA = """
CREATE TABLE thumbs (
    icon_id INTEGER PRIMARY KEY REFERENCES subjects(icon_id),
    w       INTEGER NOT NULL,
    h       INTEGER NOT NULL,
    jpeg    BLOB    NOT NULL
);
"""


def make_thumb_bytes(src: Path) -> tuple[bytes, int, int]:
    im = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    w, h = im.size
    s = THUMB_LONG_EDGE / max(w, h)
    if s < 1:
        im = im.resize((round(w * s), round(h * s)), Image.LANCZOS)
    buf = BytesIO()
    im.save(buf, "JPEG", quality=THUMB_QUALITY, optimize=True, subsampling="4:2:0")
    return buf.getvalue(), im.width, im.height


def pack_thumbs(conn: sqlite3.Connection) -> tuple[int, list[str]]:
    conn.execute("DROP TABLE IF EXISTS thumbs")
    conn.executescript(THUMBS_SCHEMA)

    icons_conn = sqlite3.connect(f"file:{ICONS}?mode=ro", uri=True)
    try:
        icon_rows = {
            row[0]: (row[1], row[2])
            for row in icons_conn.execute(
                "SELECT icon_id, category, representative_image_id FROM icons"
            )
        }
    finally:
        icons_conn.close()

    subject_ids = [row[0] for row in conn.execute("SELECT icon_id FROM subjects")]

    n_ok = 0
    skipped: list[str] = []
    for i, icon_id in enumerate(subject_ids, 1):
        category, rep_image_id = icon_rows.get(icon_id, (None, None))

        src: Path | None = None
        if category is not None and rep_image_id is not None:
            candidate = Path(FULL.format(category=category, image_id=rep_image_id))
            if candidate.exists():
                src = candidate
        if src is None:
            candidate = Path(FALLBACK.format(icon_id=icon_id))
            if candidate.exists():
                src = candidate

        if src is None:
            skipped.append(f"icon_id={icon_id} (category={category}, rep_image_id={rep_image_id})")
            continue

        try:
            jpeg_bytes, w, h = make_thumb_bytes(src)
        except Exception as exc:  # noqa: BLE001 - log and continue
            skipped.append(f"icon_id={icon_id} src={src} error={exc}")
            continue

        conn.execute(
            "INSERT INTO thumbs VALUES (?,?,?,?)",
            (icon_id, w, h, sqlite3.Binary(jpeg_bytes)),
        )
        n_ok += 1

        if n_ok % 200 == 0:
            conn.commit()
        if i % 250 == 0:
            print(f"  thumbs: {i}/{len(subject_ids)} processed, {n_ok} ok, {len(skipped)} skipped")

    conn.commit()
    return n_ok, skipped


def clean_prayer(body: str) -> tuple[str, str | None]:
    s = body.replace("\r\n", "\n").replace("\r", "\n").strip()
    head, sep, tail = s.partition("\n\nПеревод:")
    translation = tail.strip() if sep else None
    chunks: list[str] = []
    seen: set[str] = set()
    for c in (p.strip() for p in head.split("\n\n")):
        if c and c not in seen:
            seen.add(c)
            chunks.append(c)
    return "\n\n".join(chunks), translation


def clean_prayers(conn: sqlite3.Connection) -> int:
    conn.execute("ALTER TABLE prayers ADD COLUMN translation TEXT")
    rows = conn.execute("SELECT prayer_id, body FROM prayers").fetchall()
    n_translations = 0
    for prayer_id, body in rows:
        new_body, translation = clean_prayer(body)
        if translation is not None:
            n_translations += 1
        conn.execute(
            "UPDATE prayers SET body = ?, translation = ? WHERE prayer_id = ?",
            (new_body, translation, prayer_id),
        )
    conn.commit()
    return n_translations


def clean_text(t: str) -> str:
    t = t.replace("\r\n", "\n").replace("\r", "\n")
    t = re.sub(r"\(\s*\n\s*", "(", t)
    t = re.sub(r"\s*\n\s*\)", ")", t)
    t = re.sub(r"[ \t]+\n", "\n", t)
    t = re.sub(r"\n{3,}", "\n\n", t).strip()
    return t


def clean_lives_and_histories(conn: sqlite3.Connection) -> tuple[int, int]:
    lives = conn.execute("SELECT icon_id, life FROM lives").fetchall()
    for icon_id, life in lives:
        conn.execute("UPDATE lives SET life = ? WHERE icon_id = ?", (clean_text(life), icon_id))

    histories = conn.execute("SELECT icon_id, history FROM histories").fetchall()
    for icon_id, history in histories:
        conn.execute(
            "UPDATE histories SET history = ? WHERE icon_id = ?", (clean_text(history), icon_id)
        )

    conn.commit()
    return len(lives), len(histories)


def main() -> None:
    assert Path(META).exists(), f"missing {META} — run 10_build_meta_db.py first"
    assert Path(ICONS).exists(), f"missing {ICONS}"

    conn = sqlite3.connect(META)
    conn.execute("PRAGMA journal_mode=DELETE;")

    print("Step 2: packing thumbnails...")
    n_thumbs, skipped = pack_thumbs(conn)
    print(f"  thumbs done: {n_thumbs} rows, {len(skipped)} skipped")
    for s in skipped:
        print(f"    skipped: {s}")

    print("Step 3: cleaning prayers (dedupe + translation split)...")
    n_translations = clean_prayers(conn)
    print(f"  prayers cleaned: {n_translations} rows got a translation")

    print("Step 4: cleaning lives / histories whitespace...")
    n_lives, n_hist = clean_lives_and_histories(conn)
    print(f"  lives cleaned: {n_lives}, histories cleaned: {n_hist}")

    print("Step 5: meta rows, VACUUM, close...")
    conn.execute(
        "INSERT OR REPLACE INTO meta VALUES ('thumbs_long_edge', ?)", (str(THUMB_LONG_EDGE),)
    )
    conn.execute("INSERT OR REPLACE INTO meta VALUES ('thumbs_quality', ?)", (str(THUMB_QUALITY),))
    conn.commit()

    conn.execute("VACUUM")
    conn.commit()
    conn.close()

    wal = META + "-wal"
    shm = META + "-shm"
    assert not os.path.exists(wal), f"leftover {wal}"
    assert not os.path.exists(shm), f"leftover {shm}"

    size_mb = Path(META).stat().st_size / 1e6
    print(f"Done. {META}: {size_mb:.1f} MB. thumbs={n_thumbs} (skipped={len(skipped)}), "
          f"translations={n_translations}, lives={n_lives}, histories={n_hist}")


if __name__ == "__main__":
    main()
