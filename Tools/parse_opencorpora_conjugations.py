#!/usr/bin/env python3
"""
Parse annot.opcorpora.xml (OpenCorpora morphological annotation corpus) and add
form→lemma mappings to the conjugations table in rus_dictionary.sqlite.

The XML has ~2.6 million lines, so we use SAX streaming to avoid loading it all
into memory.

Structure:
  <token text="FORM">
    <tfr>
      <v>
        <l t="LEMMA">
          <g v="POS"/>
          ...
        </l>
      </v>
    </tfr>
  </token>

We extract every (form, lemma) pair where POS != PNCT (punctuation) and
form != lemma (no point adding identity mappings).

Usage:
    python3 Tools/parse_opencorpora_conjugations.py

Reads:  <project_root>/annot.opcorpora.xml
Writes: RussianOrthodoxReader/Resources/Bible/rus_dictionary.sqlite
"""

import os
import sqlite3
import xml.sax
import xml.sax.handler
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)

XML_PATH = os.path.join(PROJECT_ROOT, "annot.opcorpora.xml")
SQLITE_PATH = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "Bible", "rus_dictionary.sqlite")

# Batch size for SQLite inserts
BATCH_SIZE = 10_000


class CorpusHandler(xml.sax.handler.ContentHandler):
    def __init__(self):
        self.current_form: str = ""
        self.current_lemma: str = ""
        self.current_pos: str = ""
        self.in_token = False
        self.in_l = False
        self.pairs: set[tuple[str, str]] = set()
        self.token_count = 0
        self.start_time = time.time()

    def startElement(self, name, attrs):
        if name == "token":
            text = attrs.get("text", "")
            self.current_form = text.lower().strip()
            self.current_lemma = ""
            self.current_pos = ""
            self.in_token = True

        elif name == "l" and self.in_token:
            self.current_lemma = attrs.get("t", "").lower().strip()
            self.in_l = True
            self.current_pos = ""

        elif name == "g" and self.in_l:
            pos = attrs.get("v", "")
            if not self.current_pos:
                self.current_pos = pos

    def endElement(self, name):
        if name == "l" and self.in_l:
            # We have a complete (form, lemma, pos) triplet
            if (self.current_form
                    and self.current_lemma
                    and self.current_pos != "PNCT"
                    and self.current_form != self.current_lemma
                    and len(self.current_form) > 1
                    and len(self.current_lemma) > 1):
                self.pairs.add((self.current_form, self.current_lemma))
            self.in_l = False

        elif name == "token":
            self.in_token = False
            self.token_count += 1
            if self.token_count % 500_000 == 0:
                elapsed = time.time() - self.start_time
                print(f"  Processed {self.token_count:,} tokens, "
                      f"{len(self.pairs):,} pairs collected "
                      f"({elapsed:.0f}s elapsed)")


def main():
    if not os.path.exists(XML_PATH):
        print(f"ERROR: XML file not found at {XML_PATH}")
        return

    if not os.path.exists(SQLITE_PATH):
        print(f"ERROR: SQLite not found at {SQLITE_PATH}")
        return

    print(f"Parsing OpenCorpora XML (SAX streaming): {XML_PATH}")
    print("This may take a few minutes for 2.6M lines...")

    handler = CorpusHandler()
    xml.sax.parse(XML_PATH, handler)

    pairs = list(handler.pairs)
    print(f"\nExtracted {len(pairs):,} unique (form, lemma) pairs from {handler.token_count:,} tokens")

    # Connect to SQLite
    conn = sqlite3.connect(SQLITE_PATH)
    cur = conn.cursor()

    # Ensure conjugations table exists (matching existing schema)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS conjugations (
            form  TEXT NOT NULL,
            lemma TEXT NOT NULL
        )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_conj_form ON conjugations(form)")

    # Load existing pairs to avoid duplicates (too large to SELECT all — use INSERT OR IGNORE)
    # Add unique constraint if not present
    try:
        cur.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_conj_unique ON conjugations(form, lemma)")
    except sqlite3.OperationalError:
        pass  # Index may already exist under a different name

    print(f"Inserting into conjugations table in batches of {BATCH_SIZE:,}...")
    inserted = 0
    skipped = 0

    for i in range(0, len(pairs), BATCH_SIZE):
        batch = pairs[i:i + BATCH_SIZE]
        for form, lemma in batch:
            try:
                cur.execute("INSERT OR IGNORE INTO conjugations (form, lemma) VALUES (?, ?)", (form, lemma))
                if conn.total_changes > inserted + skipped:
                    inserted += 1
                else:
                    skipped += 1
            except sqlite3.IntegrityError:
                skipped += 1
        conn.commit()
        if (i // BATCH_SIZE) % 10 == 0:
            print(f"  Batch {i // BATCH_SIZE + 1}: {inserted:,} inserted so far")

    conn.close()

    elapsed = time.time() - handler.start_time
    print(f"\nDone in {elapsed:.0f}s")
    print(f"  Inserted: {inserted:,}")
    print(f"  Skipped (already existed): {skipped:,}")
    print(f"SQLite updated: {SQLITE_PATH}")


if __name__ == "__main__":
    main()
