#!/usr/bin/env python3
"""
build_modern.py — Download CRTB (Contemporary Russian Translation Bible)
from GitHub and build rus_modern.sqlite for RussianOrthodoxReader.

Usage:
    python3 build_modern.py                    # download + build
    python3 build_modern.py --cached           # use cached crtb.json if present
    python3 build_modern.py --input FILE.json  # use a local NDJSON file

Output: rus_modern.sqlite (same directory as this script)
Copy to:  RussianOrthodoxReader/Resources/Bible/rus_modern.sqlite
"""

import argparse
import json
import os
import sqlite3
import sys
import urllib.request

# ---------------------------------------------------------------------------
# GitHub source
# ---------------------------------------------------------------------------
CRTB_URL = (
    "https://raw.githubusercontent.com/bibleapi/bibleapi-bibles-json/master/crtb.json"
)
CACHE_FILE = os.path.join(os.path.dirname(__file__), "crtb_cache.json")
OUT_DB = os.path.join(os.path.dirname(__file__), "rus_modern.sqlite")

# ---------------------------------------------------------------------------
# Book ID mapping: CRTB standard names → our synodal book_id codes
# ---------------------------------------------------------------------------
CRTB_TO_SYNODAL: dict[str, str] = {
    # Pentateuch
    "Gen": "gen", "Exod": "exo", "Lev": "lev", "Num": "num", "Deut": "deu",
    # Historical
    "Josh": "jos", "Judg": "jdg", "Ruth": "rut",
    "1Sam": "1sa", "2Sam": "2sa",
    "1Kgs": "1ki", "2Kgs": "2ki",
    "1Chr": "1ch", "2Chr": "2ch",
    "Ezra": "ezr", "Neh": "neh", "Esth": "est",
    # Poetic / Wisdom
    "Job": "job", "Ps": "psa", "Prov": "pro", "Eccl": "ecc", "Song": "sng",
    # Major prophets
    "Isa": "isa", "Jer": "jer", "Lam": "lam", "Ezek": "eze", "Dan": "dan",
    # Minor prophets
    "Hos": "hos", "Joel": "jol", "Amos": "amo", "Obad": "oba", "Jona": "jon",
    "Mic": "mic", "Nah": "nam", "Hab": "hab", "Zeph": "zep", "Hag": "hag",
    "Zech": "zac", "Mal": "mal",
    # Gospels / Acts
    "Matt": "mat", "Mark": "mar", "Luke": "luk", "John": "joh", "Acts": "act",
    # Pauline epistles
    "Rom": "rom", "1Cor": "1co", "2Cor": "2co",
    "Gal": "gal", "Eph": "eph", "Phil": "phi", "Col": "col",
    "1Thess": "1th", "2Thess": "2th",
    "1Tim": "1ti", "2Tim": "2ti", "Titus": "tit", "Phlm": "phm", "Heb": "heb",
    # General epistles
    "Jas": "jas", "1Pet": "1pe", "2Pet": "2pe",
    "1John": "1jo", "2John": "2jo", "3John": "3jo", "Jude": "jud",
    # Revelation
    "Rev": "rev",
}


def download(url: str, dest: str) -> None:
    print(f"Downloading {url} …", end=" ", flush=True)
    req = urllib.request.Request(url, headers={"User-Agent": "RussianOrthodoxReader/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as f:
        data = resp.read()
        f.write(data)
    size_mb = os.path.getsize(dest) / 1_048_576
    print(f"done ({size_mb:.1f} MB)")


def iter_verses(path: str):
    """Yield (synodal_book_id, chapter, verse, text) from NDJSON file."""
    skipped_books: set[str] = set()
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"  Warning: bad JSON on line {lineno}: {e}", file=sys.stderr)
                continue
            crtb_id = obj.get("book_id", "")
            synodal_id = CRTB_TO_SYNODAL.get(crtb_id)
            if synodal_id is None:
                skipped_books.add(crtb_id)
                continue
            yield synodal_id, int(obj["chapter"]), int(obj["verse"]), obj["text"]

    if skipped_books:
        print(f"  Note: skipped {len(skipped_books)} unmapped book(s): {sorted(skipped_books)}")


def build_db(ndjson_path: str, out_path: str) -> int:
    """Build rus_modern.sqlite. Returns number of verses inserted."""
    if os.path.exists(out_path):
        os.remove(out_path)

    con = sqlite3.connect(out_path)
    cur = con.cursor()

    cur.executescript("""
        CREATE TABLE verses (
            book_id     TEXT    NOT NULL,
            chapter     INTEGER NOT NULL,
            verse       INTEGER NOT NULL,
            synodal_text TEXT   NOT NULL,
            PRIMARY KEY (book_id, chapter, verse)
        );
        CREATE INDEX idx_verses_book_chapter
            ON verses(book_id, chapter);
    """)

    count = 0
    print("Importing verses …", end=" ", flush=True)
    cur.executemany(
        "INSERT OR REPLACE INTO verses(book_id, chapter, verse, synodal_text) VALUES (?,?,?,?)",
        iter_verses(ndjson_path),
    )
    count = cur.execute("SELECT COUNT(*) FROM verses").fetchone()[0]
    con.commit()
    con.close()
    print(f"{count:,} verses written.")
    return count


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cached", action="store_true",
                    help="Re-use cached crtb_cache.json if it exists")
    ap.add_argument("--input", metavar="FILE",
                    help="Use a local NDJSON file instead of downloading")
    args = ap.parse_args()

    if args.input:
        ndjson_path = args.input
        if not os.path.exists(ndjson_path):
            sys.exit(f"Error: {ndjson_path} not found")
    elif args.cached and os.path.exists(CACHE_FILE):
        ndjson_path = CACHE_FILE
        print(f"Using cached file: {CACHE_FILE}")
    else:
        ndjson_path = CACHE_FILE
        download(CRTB_URL, ndjson_path)

    count = build_db(ndjson_path, OUT_DB)

    if count < 28_000:
        sys.exit(f"Error: only {count} verses imported — expected ≥30 000. "
                 "Check the source file.")

    dest_dir = os.path.join(
        os.path.dirname(__file__), "..", "..",
        "RussianOrthodoxReader", "Resources", "Bible"
    )
    dest_dir = os.path.normpath(dest_dir)
    dest_path = os.path.join(dest_dir, "rus_modern.sqlite")

    print(f"\nSuccess!  {OUT_DB}")
    print(f"\nNext step — copy to app bundle:")
    print(f"  cp '{OUT_DB}' '{dest_path}'")
    print()
    print("Then in Xcode: drag rus_modern.sqlite into the Resources/Bible group")
    print("(make sure 'Copy items if needed' and target membership are checked).")


if __name__ == "__main__":
    main()
