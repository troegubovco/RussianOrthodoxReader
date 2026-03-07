#!/usr/bin/env python3
"""
build_dictionary.py
───────────────────
Downloads Nyström's Biblical Dictionary from azbyka.ru and builds
rus_dictionary.sqlite for the Russian Orthodox Reader app.

Usage:
    pip install requests beautifulsoup4
    python3 build.py

Output:
    ../../RussianOrthodoxReader/Resources/Bible/rus_dictionary.sqlite

The dictionary (Нюстрем Э. Библейский словарь, 1874) is in the public domain.
"""

import re
import sqlite3
import time
from pathlib import Path

try:
    import requests
    from bs4 import BeautifulSoup
except ImportError:
    print("Install dependencies first:  pip install requests beautifulsoup4")
    raise

# ── Config ────────────────────────────────────────────────────────────────────

BASE_URL   = "https://azbyka.ru/otechnik/Spravochniki/slovar-nustrema/"
HEADERS    = {"User-Agent": "RussianOrthodoxReader/0.3 (dictionary builder; personal use)"}
OUT_DIR    = Path(__file__).parent.parent.parent / "RussianOrthodoxReader/Resources/Bible"
OUT_FILE   = OUT_DIR / "rus_dictionary.sqlite"
DELAY_SEC  = 1.5   # polite delay between requests

# ── Helpers ───────────────────────────────────────────────────────────────────

def fetch(url: str) -> BeautifulSoup:
    r = requests.get(url, headers=HEADERS, timeout=30)
    r.raise_for_status()
    r.encoding = "utf-8"
    time.sleep(DELAY_SEC)
    return BeautifulSoup(r.text, "html.parser")

def clean(text: str) -> str:
    text = re.sub(r"\s+", " ", text)
    return text.strip()

# ── Scraper ───────────────────────────────────────────────────────────────────

def get_chapter_links(soup: BeautifulSoup) -> list[str]:
    """Return all chapter/section URLs from the table of contents."""
    links = []
    for a in soup.select("a[href]"):
        href = a["href"]
        if "/slovar-nustrema/" in href and href != BASE_URL:
            full = href if href.startswith("http") else "https://azbyka.ru" + href
            if full not in links:
                links.append(full)
    return links

def scrape_entries_from_page(soup: BeautifulSoup) -> list[tuple[str, str]]:
    """Extract (word, definition) pairs from a dictionary page."""
    entries = []
    content = soup.find("div", class_=re.compile("article|content|text", re.I))
    if not content:
        content = soup.find("div", id=re.compile("article|content|text", re.I))
    if not content:
        return entries

    # Each entry is typically marked with bold or a heading
    current_word = None
    current_def_parts: list[str] = []

    for el in content.descendants:
        if el.name in ("b", "strong"):
            text = clean(el.get_text())
            if text and len(text) < 80:
                # Save previous entry
                if current_word and current_def_parts:
                    entries.append((current_word, clean(" ".join(current_def_parts))))
                current_word = text
                current_def_parts = []
        elif el.name in ("p", "div") and current_word:
            text = clean(el.get_text())
            if text:
                current_def_parts.append(text)

    if current_word and current_def_parts:
        entries.append((current_word, clean(" ".join(current_def_parts))))

    return entries

# ── SQLite builder ────────────────────────────────────────────────────────────

def build_sqlite(entries: list[tuple[str, str]]) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUT_FILE.exists():
        OUT_FILE.unlink()

    con = sqlite3.connect(OUT_FILE)
    cur = con.cursor()

    cur.executescript("""
        CREATE TABLE entries (
            rowid    INTEGER PRIMARY KEY,
            word     TEXT NOT NULL,
            definition TEXT NOT NULL,
            source   TEXT DEFAULT 'Нюстрем'
        );
        CREATE INDEX idx_word ON entries(lower(word));
        CREATE VIRTUAL TABLE entries_fts
            USING fts5(word, definition, content=entries, content_rowid=rowid,
                       tokenize='unicode61 remove_diacritics 0');
    """)

    cur.executemany(
        "INSERT INTO entries(word, definition) VALUES (?, ?)",
        [(w, d) for w, d in entries if w and d]
    )

    # Populate FTS index
    cur.execute("""
        INSERT INTO entries_fts(rowid, word, definition)
        SELECT rowid, word, definition FROM entries
    """)

    con.commit()
    con.close()
    print(f"\n✓ Written {len(entries):,} entries → {OUT_FILE}")

# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    print("Fetching table of contents…")
    toc = fetch(BASE_URL)
    links = get_chapter_links(toc)
    print(f"Found {len(links)} section(s).\n")

    all_entries: list[tuple[str, str]] = []

    for i, url in enumerate(links, 1):
        print(f"[{i}/{len(links)}] {url}")
        try:
            soup = fetch(url)
            page_entries = scrape_entries_from_page(soup)
            all_entries.extend(page_entries)
            print(f"    → {len(page_entries)} entries")
        except Exception as e:
            print(f"    ✗ Error: {e}")

    if not all_entries:
        print("\nNo entries scraped — check the HTML structure of azbyka.ru")
        return

    # Deduplicate by word (keep first occurrence)
    seen: set[str] = set()
    unique: list[tuple[str, str]] = []
    for w, d in all_entries:
        key = w.lower()
        if key not in seen:
            seen.add(key)
            unique.append((w, d))

    print(f"\nTotal unique entries: {len(unique):,}")
    build_sqlite(unique)

if __name__ == "__main__":
    main()
