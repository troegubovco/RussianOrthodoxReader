#!/usr/bin/env python3
"""
Parse 'Полный православный церковнославянский словарь.rtf' and merge its entries
into the existing rus_dictionary.sqlite.

The RTF file is a two-column table:
  Column 1: Church Slavonic word (with stress marks and alternate spellings)
  Column 2: Russian definition / translation

Usage:
    python3 Tools/parse_church_slavonic_rtf.py

The script reads the RTF from the project root and writes directly into:
    RussianOrthodoxReader/Resources/Bible/rus_dictionary.sqlite
"""

import re
import sqlite3
import os
import json

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)

RTF_PATH = os.path.join(PROJECT_ROOT, "Полный православный церковнославянский словарь.rtf")
SQLITE_PATH = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "Bible", "rus_dictionary.sqlite")
SOURCE = "Церковнославянский словарь"


def decode_rtf_hex(text: str) -> str:
    """Decode \\'XX hex escape sequences (Windows-1252 encoding) to Unicode."""
    def replace_hex(m):
        try:
            return bytes([int(m.group(1), 16)]).decode('windows-1252')
        except Exception:
            return ''
    return re.sub(r"\\'([0-9a-fA-F]{2})", replace_hex, text)


def decode_rtf_unicode(text: str) -> str:
    """Decode \\uc0\\uN  Unicode escape sequences used in the RTF."""
    def replace(m):
        codepoint = int(m.group(1))
        try:
            return chr(codepoint)
        except (ValueError, OverflowError):
            return ""

    # Handle \uc0\uNNNN sequences
    text = re.sub(r'\\uc0\\u(\d+)\s?', replace, text)
    # Handle standalone \uNNNN sequences
    text = re.sub(r'\\u(\d+)\s?', replace, text)
    return text


def strip_rtf_control(text: str) -> str:
    """Remove remaining RTF control words and symbols."""
    # Remove control words like \f0 \cf2 \expnd0 etc.
    text = re.sub(r'\\[a-zA-Z]+[-]?\d*\s?', '', text)
    # Remove remaining backslash sequences
    text = re.sub(r'\\\S', '', text)
    # Remove braces
    text = text.replace('{', '').replace('}', '')
    # Collapse whitespace
    text = re.sub(r'\s+', ' ', text)
    return text.strip()


def extract_cell_texts(rtf_content: str) -> list[tuple[str, str]]:
    """
    Extract (word, definition) pairs from RTF table rows.
    Each row: [cell1_content]\\cell [cell2_content]\\cell \\row
    """
    pairs = []

    # Split by \row to get table rows
    rows = re.split(r'\\row\b', rtf_content)

    for row in rows:
        # Split each row by \cell to get cells
        cells = re.split(r'\\cell\b', row)
        if len(cells) < 2:
            continue

        cell1_raw = cells[0]
        cell2_raw = cells[1]

        # Decode hex escapes (\'XX Windows-1252) THEN Unicode escapes (\uNNNN)
        cell1 = decode_rtf_hex(cell1_raw)
        cell2 = decode_rtf_hex(cell2_raw)
        cell1 = decode_rtf_unicode(cell1)
        cell2 = decode_rtf_unicode(cell2)

        # Strip RTF control sequences
        cell1 = strip_rtf_control(cell1)
        cell2 = strip_rtf_control(cell2)

        # Skip header row ("Слово" / "Толкование")
        if cell1 in ("Слово", "Слово ") or cell2.startswith("Толкование"):
            continue

        # Skip empty pairs
        if not cell1.strip() or not cell2.strip():
            continue

        # Clean up stress/accent marks that aren't needed for lookup key
        word = cell1.strip()
        definition = cell2.strip()

        # Remove standalone '-' that sometimes appears as separator
        if word == '–' or word == '-':
            continue

        pairs.append((word, definition))

    return pairs


def normalize_word(word: str) -> str:
    """Normalize word for use as dictionary key: lowercase, remove stress marks."""
    # Remove combining accent/stress marks (Unicode 0300-036F range)
    import unicodedata
    normalized = unicodedata.normalize('NFD', word)
    # Remove combining diacritical marks
    normalized = ''.join(c for c in normalized if unicodedata.category(c) != 'Mn')
    normalized = unicodedata.normalize('NFC', normalized)
    return normalized.lower().strip()


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--reparse", action="store_true",
                        help="Delete existing Church Slavonic entries and re-insert with corrected parsing")
    args = parser.parse_args()

    if not os.path.exists(RTF_PATH):
        print(f"ERROR: RTF file not found at {RTF_PATH}")
        return

    if not os.path.exists(SQLITE_PATH):
        print(f"ERROR: SQLite not found at {SQLITE_PATH}")
        return

    print(f"Reading RTF: {RTF_PATH}")
    with open(RTF_PATH, 'rb') as f:
        raw = f.read()

    # Try UTF-8 first, fall back to Latin-1 for RTF ASCII content
    try:
        rtf_content = raw.decode('utf-8')
    except UnicodeDecodeError:
        rtf_content = raw.decode('latin-1')

    print("Parsing RTF table...")
    pairs = extract_cell_texts(rtf_content)
    print(f"  Found {len(pairs)} raw entries")

    # Deduplicate by normalized word (keep first occurrence)
    seen = {}
    unique_pairs = []
    for word, definition in pairs:
        key = normalize_word(word)
        if key and key not in seen:
            seen[key] = True
            unique_pairs.append((word, definition, key))

    print(f"  {len(unique_pairs)} unique entries after deduplication")

    # Connect to SQLite
    conn = sqlite3.connect(SQLITE_PATH)
    cur = conn.cursor()

    # Ensure the entries table has the expected schema
    cur.execute("""
        CREATE TABLE IF NOT EXISTS entries (
            rowid      INTEGER PRIMARY KEY,
            word       TEXT NOT NULL,
            definition TEXT NOT NULL,
            source     TEXT DEFAULT 'Библейский словарь'
        )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_word ON entries(word COLLATE NOCASE)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_word_lower ON entries(lower(word))")

    if args.reparse:
        # Delete existing Church Slavonic entries so re-insert picks up corrected parsing
        cur.execute("DELETE FROM entries WHERE source = ?", (SOURCE,))
        deleted = conn.total_changes
        print(f"  Deleted {deleted} existing entries for re-parse")

    inserted = 0
    skipped = 0
    for word, definition, key in unique_pairs:
        if not args.reparse:
            # Skip if the exact lower-case word already exists
            cur.execute("SELECT 1 FROM entries WHERE lower(word) = ? LIMIT 1", (key,))
            if cur.fetchone():
                skipped += 1
                continue

        cur.execute(
            "INSERT INTO entries (word, definition, source) VALUES (?, ?, ?)",
            (word, definition, SOURCE)
        )
        inserted += 1

    conn.commit()
    conn.close()

    print(f"\nDone: {inserted} inserted, {skipped} skipped (already exist)")
    print(f"SQLite updated: {SQLITE_PATH}")

    # Save a preview JSON for inspection
    preview_path = os.path.join(SCRIPT_DIR, "church_slavonic_preview.json")
    with open(preview_path, 'w', encoding='utf-8') as f:
        json.dump(
            [{"word": w, "definition": d} for w, d, _ in unique_pairs[:50]],
            f, ensure_ascii=False, indent=2
        )
    print(f"Preview (first 50 entries): {preview_path}")


if __name__ == "__main__":
    main()
