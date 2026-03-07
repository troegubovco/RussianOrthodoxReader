#!/usr/bin/env python3
"""
pass4_build_sqlite.py — Build the final rus_dictionary.sqlite from Pass 2+3 data.

Creates:
  - entries table: word, definition, source
  - conjugations table: form (lowercase) → lemma (lowercase)

Schema matches what DictionaryRepository.swift expects.
"""

import json
import sqlite3
from collections import defaultdict
from config import PASS2_SUMMARY, PASS3_RESULTS, OUTPUT_DB, DICT_SOURCE


def load_pass2_summary() -> dict:
    """Load Pass 2 summary with lemma groupings."""
    if not PASS2_SUMMARY.exists():
        raise FileNotFoundError(f"Pass 2 summary not found: {PASS2_SUMMARY}")
    with open(PASS2_SUMMARY, "r", encoding="utf-8") as f:
        return json.load(f)


def load_pass3_definitions() -> dict[str, str]:
    """Load Pass 3 definitions. Returns {lemma_lower: definition}."""
    if not PASS3_RESULTS.exists():
        raise FileNotFoundError(f"Pass 3 results not found: {PASS3_RESULTS}")

    definitions: dict[str, str] = {}
    display_names: dict[str, str] = {}

    with open(PASS3_RESULTS, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue

            lemma = r.get("lemma", "").strip()
            defn = r.get("definition", "").strip()
            status = r.get("status", "OK")

            if not lemma or not defn or status in ("FAILED", "EMPTY"):
                continue

            key = lemma.lower()
            # Keep the longest/best definition if duplicates exist
            if key not in definitions or len(defn) > len(definitions[key]):
                definitions[key] = defn
                display_names[key] = lemma  # Preserve original casing

    return definitions, display_names


def build_database():
    """Build the final SQLite dictionary database."""
    # Load data
    summary = load_pass2_summary()
    lemmas = summary["lemmas"]
    definitions, display_names = load_pass3_definitions()

    print(f"Pass 2 lemmas: {len(lemmas):,}")
    print(f"Pass 3 definitions: {len(definitions):,}")

    # ── Build entries table ──────────────────────────────────────────────────

    entries = []  # (word, definition, source)
    missing_defs = 0

    for lemma_key, info in lemmas.items():
        cat = info.get("cat", "SKIP")
        if cat != "DEFINE":
            continue

        defn = definitions.get(lemma_key)
        if not defn:
            missing_defs += 1
            continue

        # Use display name from Pass 3 if available, else from Pass 2
        display = display_names.get(lemma_key, info.get("display", lemma_key))
        entries.append((display, defn, DICT_SOURCE))

    # Also add any definitions from Pass 3 not in Pass 2 summary (edge case)
    seen_lower = {e[0].lower() for e in entries}
    for key, defn in definitions.items():
        if key not in seen_lower:
            display = display_names.get(key, key)
            entries.append((display, defn, DICT_SOURCE))

    # Sort by word
    entries.sort(key=lambda x: x[0].lower())

    print(f"\nEntries to insert: {len(entries):,}")
    if missing_defs > 0:
        print(f"  DEFINE lemmas without definitions: {missing_defs}")

    # ── Build conjugations table ─────────────────────────────────────────────

    conjugations = []  # (form_lower, lemma_lower)
    entry_words_lower = {e[0].lower() for e in entries}

    for lemma_key, info in lemmas.items():
        # Only create conjugation mappings for words we have definitions for
        if lemma_key not in entry_words_lower:
            continue

        forms = info.get("forms", [])
        for form in forms:
            form_lower = form.lower()
            # Always map form to lemma (both lowercase)
            conjugations.append((form_lower, lemma_key))
            # Also add the lemma itself as a form (self-mapping)
            if lemma_key not in [f.lower() for f in forms]:
                conjugations.append((lemma_key, lemma_key))

    # Deduplicate conjugations
    conjugations = list(set(conjugations))
    conjugations.sort()

    print(f"Conjugation mappings: {len(conjugations):,}")

    # ── Write SQLite ─────────────────────────────────────────────────────────

    OUTPUT_DB.parent.mkdir(parents=True, exist_ok=True)
    if OUTPUT_DB.exists():
        OUTPUT_DB.unlink()

    con = sqlite3.connect(str(OUTPUT_DB))
    cur = con.cursor()

    # Create entries table (exact schema from build_combined.py)
    cur.executescript("""
        CREATE TABLE entries (
            rowid      INTEGER PRIMARY KEY,
            word       TEXT NOT NULL,
            definition TEXT NOT NULL,
            source     TEXT DEFAULT 'Библейский словарь'
        );
        CREATE INDEX idx_word       ON entries(word COLLATE NOCASE);
        CREATE INDEX idx_word_lower ON entries(lower(word));
    """)

    cur.executemany(
        "INSERT INTO entries(word, definition, source) VALUES (?, ?, ?)",
        entries,
    )
    print(f"\nInserted {len(entries):,} entries")

    # Create conjugations table
    cur.execute("""
        CREATE TABLE conjugations (
            form  TEXT NOT NULL,
            lemma TEXT NOT NULL
        );
    """)
    cur.execute("CREATE INDEX idx_conj_form ON conjugations(form);")

    cur.executemany(
        "INSERT INTO conjugations(form, lemma) VALUES (?, ?)",
        conjugations,
    )
    print(f"Inserted {len(conjugations):,} conjugation mappings")

    con.commit()

    # ── Validation ───────────────────────────────────────────────────────────

    print("\n── Validation ──")

    # Count
    cur.execute("SELECT COUNT(*) FROM entries")
    entry_count = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM conjugations")
    conj_count = cur.fetchone()[0]

    # Spot check: known important words
    test_words = [
        "агнец", "вретище", "десница", "горница", "ефод", "скиния",
        "аминь", "аллилуия", "фарисей", "мытарь", "талант",
        "авраам", "моисей", "давид", "иерусалим", "вифлеем",
    ]
    found = 0
    missing = []
    for w in test_words:
        cur.execute("SELECT word, substr(definition, 1, 60) FROM entries WHERE lower(word) = ?", (w,))
        row = cur.fetchone()
        if row:
            found += 1
            print(f"  ✓ {row[0]}: {row[1]}...")
        else:
            # Try via conjugation
            cur.execute("SELECT lemma FROM conjugations WHERE form = ?", (w,))
            lemma_row = cur.fetchone()
            if lemma_row:
                cur.execute("SELECT word, substr(definition, 1, 60) FROM entries WHERE lower(word) = ?",
                           (lemma_row[0],))
                row = cur.fetchone()
                if row:
                    found += 1
                    print(f"  ✓ {w} → {row[0]}: {row[1]}...")
                    continue
            missing.append(w)
            print(f"  ✗ {w}: NOT FOUND")

    print(f"\nSpot check: {found}/{len(test_words)} found")
    if missing:
        print(f"  Missing: {', '.join(missing)}")

    # Sample random entries
    cur.execute("SELECT word, substr(definition, 1, 80) FROM entries ORDER BY RANDOM() LIMIT 5")
    print("\nRandom sample entries:")
    for row in cur.fetchall():
        print(f"  {row[0]}: {row[1]}...")

    # Average definition length
    cur.execute("SELECT AVG(LENGTH(definition)), MIN(LENGTH(definition)), MAX(LENGTH(definition)) FROM entries")
    avg_len, min_len, max_len = cur.fetchone()
    print(f"\nDefinition lengths: avg={avg_len:.0f}, min={min_len}, max={max_len}")

    con.close()

    size_mb = OUTPUT_DB.stat().st_size / (1024 * 1024)
    print(f"\n✓ Built {OUTPUT_DB}")
    print(f"  {entry_count:,} dictionary entries")
    print(f"  {conj_count:,} conjugation mappings")
    print(f"  {size_mb:.2f} MB")


if __name__ == "__main__":
    build_database()
