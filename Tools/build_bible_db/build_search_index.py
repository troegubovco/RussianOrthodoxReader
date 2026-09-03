#!/usr/bin/env python3
"""
Build the Bible full-text search index and curated topic index in place, inside
RussianOrthodoxReader/Resources/Bible/rus_synodal.sqlite.

Adds three tables to the existing, checked-in rus_synodal.sqlite (does NOT touch
`books` / `verses` — the corpus itself is untouched):

  verses_fts         contentless FTS5 over Snowball stems of each verse's text,
                      dual-indexed with the conjugation-map lemma's stem when it
                      differs from the surface stem (see search_design.md §1, §4.1).
  bible_conjugations  form -> lemma, trimmed to forms that actually occur in the
                      Synodal text, so the query side can expand without opening
                      the much larger rus_dictionary.sqlite.
  bible_topics        curated "story I remember, not the words" index
                      (Tools/data/bible_topics.json), so e.g. "блудный сын" finds
                      Лк 15 even though that exact phrase never occurs in the text.

Safety: never opens the checked-in .sqlite files in place. Everything happens on
copies in a scratch work directory; the result is copied back over the repo path
in one shutil.copyfile at the very end. See the "Data hazard" note this script's
task was built from: a sandboxed sqlite3/python process can silently truncate a
repo file to 0 bytes if opened in place, so we never take that risk.

Idempotent: DROP TABLE IF EXISTS on every table this script owns, so re-running
it (e.g. after editing bible_topics.json) is always safe.

Usage:
    python3 Tools/build_bible_db/build_search_index.py [--work-dir DIR]

`--work-dir` is optional; a fresh temp dir is used by default. Passing an
existing dir lets you reuse copies you already made (e.g. during design/
research) instead of re-copying the 9.3 MB Bible + 23 MB dictionary DB.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.dirname(SCRIPT_DIR)
PROJECT_ROOT = os.path.dirname(TOOLS_DIR)
sys.path.insert(0, TOOLS_DIR)

from russian_stemmer import stem  # noqa: E402  (Tools/russian_stemmer.py)

BIBLE_DB_PATH = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "Bible", "rus_synodal.sqlite")
DICT_DB_PATH = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "Bible", "rus_dictionary.sqlite")
TOPICS_PATH = os.path.join(TOOLS_DIR, "data", "bible_topics.json")

# Matches Unicode letter runs only (no digits, no underscore) — the same shape
# as Shared/SearchNormalizer.swift's `tokens(_:)` (splits on any non-letter).
TOKEN_RE = re.compile(r"[^\W\d_]+", re.UNICODE)


def tokenize(text: str) -> list[str]:
    """Lowercase, ё→е, split into letter-only tokens. Mirrors the Swift
    SearchNormalizer.tokens pipeline (minus the U+0301 stress strip, which the
    Synodal text and bible_topics.json don't carry)."""
    return TOKEN_RE.findall(text.lower().replace("ё", "е"))


def index_text(text: str, conj: dict[str, str]) -> str:
    """Dual-indexed stems for one verse: surface stem, plus the conjugation
    lemma's stem when it differs (search_design.md §4.1)."""
    out: list[str] = []
    for w in tokenize(text):
        a = stem(w)
        out.append(a)
        lemma = conj.get(w)
        if lemma:
            b = stem(lemma)
            if b != a:
                out.append(b)
    return " ".join(out)


def build_conjugation_map(dict_db_path: str, vocabulary: set[str]) -> dict[str, str]:
    """form -> lemma, trimmed to `vocabulary` (the Synodal text's own word types).
    A form can have several lemmas in the source map (measured: inconsistent,
    e.g. "любит" -> "люблю"); we pick one deterministically (lexicographically
    first lemma) so the shipped `bible_conjugations` table and the stems baked
    into `verses_fts` always agree with each other."""
    conn = sqlite3.connect(dict_db_path)
    try:
        raw: dict[str, list[str]] = defaultdict(list)
        for form, lemma in conn.execute("SELECT form, lemma FROM conjugations"):
            f = form.lower()
            if f in vocabulary:
                raw[f].append(lemma.lower())
    finally:
        conn.close()
    return {form: sorted(lemmas)[0] for form, lemmas in raw.items()}


def load_topics() -> list[dict]:
    """`bible_topics.json` is `{"_comment": ..., "_format": ..., "topics": [...]}`.

    Deviation from the spec's compressed illustrative example (a dict keyed by
    display_ref, e.g. `"1 Кор 13": {"title": ..., "tags": ...}`): each entry here
    carries its book_id/chapter/verse_start/verse_end explicitly instead of being
    derived by re-parsing the Russian display_ref text. Reason: doing that
    derivation would mean porting a second, Python-side copy of
    ReadingReferenceParser + BookAliasMapper's alias table just for JSON
    authoring convenience. Explicit fields are validated directly against the
    DB by `validate_and_insert_topics` below, which is a stronger correctness
    guarantee than trusting a hand-rolled parse of free-text references.
    """
    with open(TOPICS_PATH, encoding="utf-8") as f:
        data = json.load(f)
    return data["topics"]


def validate_and_insert_topics(conn: sqlite3.Connection, topics: list[dict]) -> list[str]:
    """Verifies every topic's book/chapter/(verse) exists in this DB copy before
    inserting. Returns a list of problem strings (empty = all good)."""
    problems: list[str] = []
    books = {row[0]: row[1] for row in conn.execute("SELECT book_id, chapter_count FROM books")}

    for i, t in enumerate(topics):
        book_id = t["book_id"]
        chapter = t["chapter"]
        verse_start = t.get("verse_start")
        verse_end = t.get("verse_end")
        label = t.get("title", f"#{i}")

        if book_id not in books:
            problems.append(f"{label}: unknown book_id {book_id!r}")
            continue
        if not (1 <= chapter <= books[book_id]):
            problems.append(f"{label}: chapter {chapter} out of range for {book_id} (has {books[book_id]})")
            continue

        entry_ok = True
        if verse_start is not None:
            row = conn.execute(
                "SELECT COUNT(*) FROM verses WHERE book_id=? AND chapter=? AND verse=?",
                (book_id, chapter, verse_start),
            ).fetchone()
            if row[0] == 0:
                problems.append(f"{label}: verse {book_id} {chapter}:{verse_start} not found")
                entry_ok = False
        if verse_end is not None:
            row = conn.execute(
                "SELECT COUNT(*) FROM verses WHERE book_id=? AND chapter=? AND verse=?",
                (book_id, chapter, verse_end),
            ).fetchone()
            if row[0] == 0:
                problems.append(f"{label}: verse {book_id} {chapter}:{verse_end} not found")
                entry_ok = False
        if not entry_ok:
            continue

        tags_s = " ".join(stem(w) for w in tokenize(t["tags"]))
        conn.execute(
            "INSERT INTO bible_topics (title, tags_s, book_id, chapter, verse_start, verse_end, display_ref) "
            "VALUES (?,?,?,?,?,?,?)",
            (t["title"], tags_s, book_id, chapter, verse_start, verse_end, t["display_ref"]),
        )

    return problems


def build(work_bible_path: str, work_dict_path: str) -> tuple[int, int, list[str]]:
    """Returns (topic_count, verses_fts_count, problems)."""
    conn = sqlite3.connect(work_bible_path)
    try:
        conn.execute("DROP TABLE IF EXISTS verses_fts")
        conn.execute(
            """
            CREATE VIRTUAL TABLE verses_fts USING fts5(
                stems,
                content='',
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )
        # No prefix= index: an unindexed `слов*` query measured 0.2 ms on 37086
        # verses (search_design.md §4.1) — not worth the extra file size.

        conn.execute("DROP TABLE IF EXISTS bible_conjugations")
        conn.execute(
            """
            CREATE TABLE bible_conjugations (
                form  TEXT PRIMARY KEY,
                lemma TEXT NOT NULL
            ) WITHOUT ROWID
            """
        )

        conn.execute("DROP TABLE IF EXISTS bible_topics")
        conn.execute(
            """
            CREATE TABLE bible_topics (
                id          INTEGER PRIMARY KEY,
                title       TEXT NOT NULL,
                tags_s      TEXT NOT NULL,
                book_id     TEXT NOT NULL,
                chapter     INTEGER NOT NULL,
                verse_start INTEGER,
                verse_end   INTEGER,
                display_ref TEXT NOT NULL
            )
            """
        )
        conn.execute("DROP INDEX IF EXISTS idx_topics_book")
        conn.execute("CREATE INDEX idx_topics_book ON bible_topics(book_id, chapter)")

        # --- vocabulary + conjugation map -----------------------------------
        vocabulary: set[str] = set()
        verse_rows = conn.execute("SELECT rowid, synodal_text FROM verses").fetchall()
        for _rowid, text in verse_rows:
            vocabulary.update(tokenize(text))

        conj = build_conjugation_map(work_dict_path, vocabulary)
        conn.executemany(
            "INSERT INTO bible_conjugations (form, lemma) VALUES (?, ?)",
            list(conj.items()),
        )

        # --- verses_fts -------------------------------------------------------
        fts_rows = [(rowid, index_text(text, conj)) for rowid, text in verse_rows]
        conn.executemany("INSERT INTO verses_fts(rowid, stems) VALUES (?, ?)", fts_rows)

        # --- bible_topics -------------------------------------------------------
        topics = load_topics()
        problems = validate_and_insert_topics(conn, topics)

        conn.commit()

        conn.execute("INSERT INTO verses_fts(verses_fts) VALUES ('optimize')")
        conn.commit()
        conn.execute("VACUUM")

        topic_count = conn.execute("SELECT COUNT(*) FROM bible_topics").fetchone()[0]
        fts_count = conn.execute("SELECT COUNT(*) FROM verses_fts").fetchone()[0]
        return topic_count, fts_count, problems
    finally:
        conn.close()


def verify(work_bible_path: str) -> list[str]:
    """Sanity checks against the just-built DB. Returns a list of failure strings."""
    failures: list[str] = []
    conn = sqlite3.connect(work_bible_path)
    try:
        conn.execute("SELECT 1 FROM verses_fts LIMIT 1")  # hasFTS-style probe

        n = conn.execute("SELECT COUNT(*) FROM verses_fts WHERE verses_fts MATCH '\"любов\"'").fetchone()[0]
        if n <= 0:
            failures.append(f"verses_fts MATCH '\"любов\"' returned {n} rows, expected > 0")

        verse_count = conn.execute("SELECT COUNT(*) FROM verses").fetchone()[0]
        fts_count = conn.execute("SELECT COUNT(*) FROM verses_fts").fetchone()[0]
        if verse_count != fts_count:
            failures.append(f"verses has {verse_count} rows but verses_fts has {fts_count}")

        # A verses_fts.rowid must resolve back to a real verse — rowid drift
        # would silently point search results at the wrong verse.
        mismatched = conn.execute(
            """
            SELECT COUNT(*) FROM verses_fts f
            LEFT JOIN verses v ON v.rowid = f.rowid
            WHERE v.rowid IS NULL
            """
        ).fetchone()[0]
        if mismatched:
            failures.append(f"{mismatched} verses_fts rows have no matching verses.rowid")

        topic_count = conn.execute("SELECT COUNT(*) FROM bible_topics").fetchone()[0]
        if topic_count < 60:
            failures.append(f"bible_topics has only {topic_count} rows, expected >= 60")
    finally:
        conn.close()
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", default=None, help="Scratch directory (default: fresh temp dir)")
    args = parser.parse_args()

    work_dir = args.work_dir or tempfile.mkdtemp(prefix="bible_search_index_")
    os.makedirs(work_dir, exist_ok=True)
    work_bible = os.path.join(work_dir, "rus_synodal.sqlite")
    work_dict = os.path.join(work_dir, "rus_dictionary.sqlite")

    before_size = os.path.getsize(BIBLE_DB_PATH)
    print(f"Copying {BIBLE_DB_PATH} ({before_size} bytes) -> {work_bible}")
    shutil.copyfile(BIBLE_DB_PATH, work_bible)
    print(f"Copying {DICT_DB_PATH} -> {work_dict}")
    shutil.copyfile(DICT_DB_PATH, work_dict)

    topic_count, fts_count, build_problems = build(work_bible, work_dict)
    print(f"Built verses_fts: {fts_count} rows; bible_topics: {topic_count} rows")

    if build_problems:
        print("\nPROBLEMS (bad topic entries were skipped, not inserted):")
        for p in build_problems:
            print("  !", p)

    failures = verify(work_bible)
    if failures:
        print("\nVERIFICATION FAILED:")
        for f in failures:
            print("  !", f)

    if build_problems or failures:
        print(f"\nNOT copying back — fix the problems above and re-run. "
              f"({work_bible} left in place for inspection.)")
        return 1

    after_size = os.path.getsize(work_bible)
    shutil.copyfile(work_bible, BIBLE_DB_PATH)
    print(f"\nWrote {BIBLE_DB_PATH}: {before_size} -> {after_size} bytes "
          f"(+{after_size - before_size})")
    print("  validation: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
