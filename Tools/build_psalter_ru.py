#!/usr/bin/env python3
"""
Assembles the Russian Synodal text (text_ru) of each Psalter kathisma
(psaltir.kafizma-1 .. psaltir.kafizma-20), mirroring the rubric structure
(*Псалом N*, *Слава*, and kathisma 17's *Среда́:* mid-psalm marker) of the
existing Church-Slavonic text_cs in Tools/data/molitvoslov_raw.json.

Reads the bundled Synodal Bible DB **read-only** (a plain
`sqlite3.connect('file:...?mode=ro', uri=True)` — never writes, so it is
safe to point at the real repo copy at
RussianOrthodoxReader/Resources/Bible/rus_synodal.sqlite) and derives psalm
boundaries purely from text_cs, so it stays correct if the scrape is ever
refreshed.

Exposes `build_kathisma_translations(bible_db_path, raw_path) -> dict[str, str]`
mapping "psaltir.kafizma-N" -> Russian psalm-body text (NOT including the
trailing troparia/prayer "tail" — see build_prayers_db.py, which appends the
tail separately from prayer_translations.json's "psaltir.kafizma-N.tail" key
when present, or falls back to the original Church-Slavonic tail otherwise).

Usage (standalone, for inspection/debugging):
    python3 Tools/build_psalter_ru.py [--bible-db PATH] [--raw PATH]
Normally this module is just imported by build_prayers_db.py — running it
directly only prints a summary, it does not write prayers.sqlite itself.
"""
import argparse
import json
import os
import re
import sqlite3

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_BIBLE_DB = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "Bible", "rus_synodal.sqlite")
DEFAULT_RAW_PATH = os.path.join(SCRIPT_DIR, "data", "molitvoslov_raw.json")

TAIL_RE = re.compile(r"\*По \d+-й кафисме.*?\*", re.DOTALL)
TOKEN_RE = re.compile(r"(\*[^*]+\*)")
PSALM_HEADING_RE = re.compile(r"^\*Псалом (\d+)(?:\s*—.*)?\*$")

# Kathisma 17 (Psalm 118, 176 verses) is the one kathisma where "Слава" falls
# *inside* the psalm rather than between psalms — plus a *Среда́:* ("Середина
# псалма" — the psalm's midpoint) marker. Verse ranges below were confirmed
# against azbyka's own parallel-translation edition
# (azbyka.ru/molitvoslov/psaltir-po-kafizmam-s-perevodom.html), which marks
# the same four spans with inline verse numbers: 1–72 / 73–93 / 94–131 /
# 132–176.
KATHISMA_17_SEGMENTS = [
    (1, 72, "*Слава*"),
    (73, 93, "*Среда:*"),
    (94, 131, "*Слава*"),
    (132, 176, "*Слава*"),
]


def load_psalm_verses(conn: sqlite3.Connection, chapter: int) -> list[str]:
    rows = conn.execute(
        "SELECT synodal_text FROM verses WHERE book_id='psa' AND chapter=? ORDER BY verse",
        (chapter,),
    ).fetchall()
    return [r[0].strip() for r in rows]


def psalm_ru_text(conn: sqlite3.Connection, chapter: int, verse_from: int | None = None,
                   verse_to: int | None = None) -> str | None:
    rows = conn.execute(
        "SELECT verse, synodal_text FROM verses WHERE book_id='psa' AND chapter=? ORDER BY verse",
        (chapter,),
    ).fetchall()
    if not rows:
        return None
    if verse_from is not None:
        rows = [r for r in rows if verse_from <= r[0] <= verse_to]
    return " ".join(text.strip() for _, text in rows)


def build_kathisma_body(conn: sqlite3.Connection, n: int, text_cs: str) -> tuple[str, str] | None:
    """Returns (ru_body, cs_tail) for kathisma n, or None if the DB lacks a
    psalm this kathisma needs (e.g. Psalm 151 missing from an older Bible DB)."""
    m = TAIL_RE.search(text_cs)
    if not m:
        return None
    body_cs = text_cs[: m.start()].rstrip()
    tail_cs = text_cs[m.start():]

    if n == 17:
        psalm_text = psalm_ru_text(conn, 118)
        if psalm_text is None:
            return None
        # Re-split by verse ranges for the *Слава*/*Среда:* markers.
        parts = ["*Псалом 118*", ""]
        pieces = []
        for lo, hi, marker in KATHISMA_17_SEGMENTS:
            seg = psalm_ru_text(conn, 118, lo, hi)
            if seg is None:
                return None
            pieces.append(seg)
        out = ["*Псалом 118*", pieces[0], "*Слава*", pieces[1], "*Среда:*",
               pieces[2], "*Слава*", pieces[3], "*Слава*"]
        return "\n\n".join(out), tail_cs

    tokens = [t for t in TOKEN_RE.split(body_cs) if t.strip()]
    out_parts: list[str] = []
    current_psalm: int | None = None
    for tok in tokens:
        if tok.startswith("*") and tok.endswith("*"):
            hm = PSALM_HEADING_RE.match(tok.strip())
            if hm:
                current_psalm = int(hm.group(1))
                out_parts.append(tok.strip())
            else:
                # *Слава* (or, in principle, any other same-for-both-languages rubric)
                out_parts.append(tok.strip())
        else:
            if current_psalm is None:
                # Stray non-psalm text before the first heading — shouldn't happen.
                continue
            ru = psalm_ru_text(conn, current_psalm)
            if ru is None:
                return None
            out_parts.append(ru)
    return "\n\n".join(out_parts), tail_cs


def build_kathisma_translations(bible_db_path: str = DEFAULT_BIBLE_DB,
                                 raw_path: str = DEFAULT_RAW_PATH) -> dict[str, str]:
    """Returns {"psaltir.kafizma-N": ru_body_text} for every kathisma the
    bundled Synodal DB has full psalm coverage for (missing/partial ones are
    silently skipped — build_prayers_db.py just leaves text_ru unset there)."""
    with open(raw_path, encoding="utf-8") as f:
        raw = json.load(f)
    by_slug = {p["slug"]: p for p in raw["prayers"]}

    uri = f"file:{bible_db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        result: dict[str, str] = {}
        for n in range(1, 21):
            slug = f"psaltir.kafizma-{n}"
            p = by_slug.get(slug)
            if p is None:
                continue
            built = build_kathisma_body(conn, n, p["text_cs"])
            if built is None:
                continue
            ru_body, _tail_cs = built
            result[slug] = ru_body
        return result
    finally:
        conn.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bible-db", default=DEFAULT_BIBLE_DB)
    ap.add_argument("--raw", default=DEFAULT_RAW_PATH)
    args = ap.parse_args()

    translations = build_kathisma_translations(args.bible_db, args.raw)
    print(f"Built RU psalm bodies for {len(translations)}/20 kathismas from {args.bible_db}")
    missing = [n for n in range(1, 21) if f"psaltir.kafizma-{n}" not in translations]
    if missing:
        print("  missing:", missing)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
