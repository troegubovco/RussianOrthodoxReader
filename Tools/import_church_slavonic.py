#!/usr/bin/env python3
"""
Import Полный Церковнославянский Словарь.json into rus_dictionary.sqlite.

Only imports entries whose Russian word form actually appears in the Russian
Synodal Bible text (rus_synodal.sqlite), excluding words already covered by
the Библейский словарь.

Usage (from project root):
    python3 Tools/import_church_slavonic.py [--dry-run]
"""
import argparse
import json
import os
import re
import sqlite3

SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
JSON_PATH    = os.path.join(PROJECT_ROOT, "Полный Церковнославянский Словарь.json")
SQLITE_PATH  = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources",
                            "Bible", "rus_dictionary.sqlite")
BIBLE_PATH   = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources",
                            "Bible", "rus_synodal.sqlite")
SOURCE    = "Церковнославянский словарь"
SEPARATOR = "\u2013"  # en-dash U+2013


def load_synodal_words():
    """Return lowercase set of all words appearing in the Russian Synodal Bible."""
    conn = sqlite3.connect(BIBLE_PATH)
    cur = conn.cursor()
    cur.execute("SELECT synodal_text FROM verses")
    words = set()
    for (text,) in cur.fetchall():
        for w in re.findall(r'[а-яёА-ЯЁ]+', text):
            words.add(w.lower())
    conn.close()
    return words


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true",
                        help="Print stats without writing to database")
    args = parser.parse_args()

    print("Loading Synodal Bible words...")
    synodal_words = load_synodal_words()
    print(f"Unique words in Synodal Bible: {len(synodal_words):,}")

    # Load JSON and deduplicate by Russian form
    with open(JSON_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    print(f"Loaded {len(data):,} JSON entries")

    best = {}
    for entry in data:
        raw = entry["word"]
        if SEPARATOR not in raw:
            continue
        cs, rus = raw.split(SEPARATOR, 1)
        cs, rus = cs.strip(), rus.strip()
        if not cs or not rus or "http" in rus or "HYPERLINK" in rus:
            continue
        key = rus.lower()
        enriched = entry.get("enriched_definition") or entry.get("definition", "")
        if key not in best or len(enriched) > len(best[key]["enriched"]):
            best[key] = {"rus": rus, "enriched": enriched}

    print(f"Unique Russian words in JSON: {len(best):,}")

    conn = sqlite3.connect(SQLITE_PATH)
    cur  = conn.cursor()

    # Load existing biblical dictionary words (skip these)
    cur.execute("SELECT lower(word) FROM entries WHERE source='Библейский словарь'")
    biblical = set(r[0] for r in cur.fetchall())

    rows_insert, skipped_biblical, skipped_not_in_bible = [], 0, 0
    for key, rec in best.items():
        if key not in synodal_words:
            skipped_not_in_bible += 1
            continue
        if key in biblical:
            skipped_biblical += 1
            continue
        rus_word = rec["rus"][0].upper() + rec["rus"][1:] if rec["rus"] else rec["rus"]
        rows_insert.append((rus_word, rec["enriched"], SOURCE))

    print(f"\nTo insert:                    {len(rows_insert):,}")
    print(f"Skipped (not in Bible text):  {skipped_not_in_bible:,}")
    print(f"Skipped (biblical dict):      {skipped_biblical:,}")

    if args.dry_run:
        print("\n[DRY RUN] No changes written.")
        conn.close()
        return

    cur.executemany(
        "INSERT INTO entries (word, definition, source) VALUES (?, ?, ?)",
        rows_insert
    )
    conn.commit()
    cur.execute("REINDEX")
    conn.commit()

    cur.execute("SELECT source, COUNT(*) FROM entries GROUP BY source")
    print("\nFinal DB counts:")
    for row in cur.fetchall():
        print(f"  {row[0]}: {row[1]:,}")
    cur.execute("SELECT COUNT(*) FROM entries")
    print(f"  TOTAL: {cur.fetchone()[0]:,}")

    conn.close()
    print("\nDone.")


if __name__ == "__main__":
    main()
