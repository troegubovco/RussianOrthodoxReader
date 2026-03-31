#!/usr/bin/env python3
"""
Scrape pravicon.com catalog pages to build an index of all icons.

Fetches the four catalog pages (/s, /b, /i, /a) and extracts
(icon_id, name, category) for every entry.

Usage:
    python3 Tools/scrape_pravicon_index.py [--output Tools/data/pravicon_index.json]
"""
import argparse
import gzip
import json
import os
import re
import time
import urllib.request


BASE_URL = "https://pravicon.com"

CATALOGS = [
    ("saints", "/s"),
    ("theotokos", "/b"),
    ("christ", "/i"),
    ("angels", "/a"),
]


def fetch_page(url: str, retries: int = 3) -> str | None:
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "RussianOrthodoxReader/1.0 (icon catalog builder)",
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Encoding": "gzip, deflate",
            })
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                return raw.decode("utf-8", errors="replace")
        except Exception as e:
            if attempt < retries - 1:
                print(f"  retry {attempt + 1} ({e})")
                time.sleep(2 * (attempt + 1))
            else:
                print(f"  FAILED: {e}")
                return None
    return None


def extract_icon_links(html: str, category: str) -> list[dict]:
    """Extract all /icon-{ID} links with their display text."""
    entries_by_id: dict[int, str] = {}
    # Links use single or double quotes, may have full URL or just path
    for m in re.finditer(
        r"""href=['"](?:https?://pravicon\.com)?/icon-(\d+)['"][^>]*>(.*?)</a>""",
        html, re.DOTALL,
    ):
        icon_id = int(m.group(1))
        name = re.sub(r"<[^>]+>", "", m.group(2)).strip()
        name = re.sub(r"\s+", " ", name)
        # Keep the first non-empty name for each ID
        if name and icon_id not in entries_by_id:
            entries_by_id[icon_id] = name
    return [
        {"icon_id": icon_id, "name": name, "category": category}
        for icon_id, name in entries_by_id.items()
    ]


def main():
    parser = argparse.ArgumentParser(description="Scrape pravicon.com icon index")
    parser.add_argument("--output", type=str, default=None, help="Output JSON path")
    args = parser.parse_args()

    if args.output is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        os.makedirs(os.path.join(script_dir, "data"), exist_ok=True)
        args.output = os.path.join(script_dir, "data", "pravicon_index.json")

    all_entries = []

    for category, path in CATALOGS:
        url = f"{BASE_URL}{path}"
        print(f"Fetching {category} ({url}) ...", end=" ", flush=True)
        html = fetch_page(url)
        if html is None:
            print("FAILED")
            continue
        entries = extract_icon_links(html, category)
        print(f"{len(entries)} entries")
        all_entries.extend(entries)
        time.sleep(1.0)

    # Sort by icon_id
    all_entries.sort(key=lambda e: e["icon_id"])

    # Save
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(all_entries, f, ensure_ascii=False, indent=2)

    print(f"\nTotal: {len(all_entries)} entries")
    for category, _ in CATALOGS:
        count = sum(1 for e in all_entries if e["category"] == category)
        print(f"  {category}: {count}")
    print(f"Saved to: {args.output}")


if __name__ == "__main__":
    main()
