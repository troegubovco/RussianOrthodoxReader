#!/usr/bin/env python3
"""
Scrape individual icon detail pages from pravicon.com.

Reads the index JSON produced by scrape_pravicon_index.py and fetches
each /icon-{ID} page to extract metadata and image URLs.

Usage:
    python3 Tools/scrape_pravicon_details.py [--index Tools/data/pravicon_index.json]
                                             [--output Tools/data/pravicon_details.json]
                                             [--delay 1.0]
                                             [--max-image-pages 3]
"""
import argparse
import gzip
import json
import os
import re
import time
import urllib.request


BASE_URL = "https://pravicon.com"


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


def html_to_text(html: str) -> str:
    """Strip HTML tags and decode common entities."""
    entities = [
        ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", '"'), ("&apos;", "'"),
        ("&#039;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&laquo;", "\u00ab"),
        ("&raquo;", "\u00bb"), ("&ndash;", "\u2013"), ("&mdash;", "\u2014"),
        ("&hellip;", "\u2026"), ("&minus;", "\u2212"), ("&shy;", ""),
        ("\u00a0", " "),
    ]
    result = html
    for ent, rep in entities:
        result = result.replace(ent, rep)
    result = re.sub(r"&#x([0-9A-Fa-f]+);", lambda m: chr(int(m.group(1), 16)), result)
    result = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), result)
    result = re.sub(r"<br\s*/?>", "\n", result)
    result = re.sub(r"<[^>]+>", " ", result)
    return re.sub(r"[ \t]+", " ", result).strip()


def extract_feast_days(html: str) -> list[str]:
    """Extract feast day dates (e.g., 'Июль 20', 'Май 22')."""
    dates = []

    # Saints use "День памяти:" inside biography text
    for m in re.finditer(r"День памяти:\s*(.+?)(?:\r?\n|<)", html):
        text = html_to_text(m.group(1)).strip()
        if text:
            for part in re.split(r"[;,]", text):
                part = part.strip()
                if part:
                    dates.append(part)

    # Theotokos icons use "Дни празднования:" with <li> items
    if not dates:
        m = re.search(r"Дни празднования:</b>.*?<ul>(.*?)</ul>", html, re.DOTALL)
        if m:
            for li in re.finditer(r"<li>.*?<b>(.*?)</b>", m.group(1), re.DOTALL):
                text = html_to_text(li.group(1)).strip()
                if text:
                    dates.append(text)

    return dates


def extract_keywords(html: str) -> list[str]:
    """Extract keywords from 'Ключевые слова:' section."""
    # Pattern: <b>Ключевые слова:</b><br>keywords</p>
    m = re.search(r"Ключевые слова:</b><br>(.*?)</p>", html, re.DOTALL)
    if not m:
        return []
    text = html_to_text(m.group(1))
    return [kw.strip() for kw in text.split(",") if kw.strip()]


def extract_biography(html: str) -> str | None:
    """Extract biography text (житие)."""
    # Pattern: житие</a></b><br>TEXT
    # The biography is inside a div.inner after the житие link
    m = re.search(
        r"""жити[её]</a></b><br>(.*?)(?:</div>|<p><b>)""",
        html, re.DOTALL | re.IGNORECASE,
    )
    if m:
        text = html_to_text(m.group(1)).strip()
        if len(text) > 2000:
            text = text[:2000] + "..."
        return text if text else None

    # Fallback: look for description section
    m = re.search(
        r"""Описани[ея]\s+иконы.*?</b><br>(.*?)(?:</div>|<p><b>)""",
        html, re.DOTALL | re.IGNORECASE,
    )
    if m:
        text = html_to_text(m.group(1)).strip()
        if len(text) > 2000:
            text = text[:2000] + "..."
        return text if text else None

    return None


def extract_thumbnail_urls(html: str) -> list[str]:
    """Extract all thumbnail image URLs from the page."""
    urls = []
    seen = set()
    for m in re.finditer(r'/images/icons/\d+/(\d+)_t\.jpg', html):
        url = m.group(0)
        if url not in seen:
            seen.add(url)
            urls.append(url)
    return urls


def extract_total_images(html: str) -> int:
    """Extract total image count from pagination."""
    # Count may be plain text or inside an <a> tag
    m = re.search(r"Всего изображений:\s*(?:<[^>]+>)?(\d+)", html)
    return int(m.group(1)) if m else 0


def extract_page_count(html: str) -> int:
    """Extract number of image pages from pagination."""
    # Look for page numbers in pagination: getImages('i',16) would mean 16 pages
    pages = re.findall(r"getImages\([^,]+,\s*(\d+)\)", html)
    if pages:
        return max(int(p) for p in pages)
    return 1


def scrape_icon_detail(icon_id: int, max_image_pages: int = 3) -> dict:
    """Scrape a single icon detail page."""
    url = f"{BASE_URL}/icon-{icon_id}"
    html = fetch_page(url)
    if html is None:
        return {"icon_id": icon_id, "error": "fetch_failed"}

    feast_days = extract_feast_days(html)
    keywords = extract_keywords(html)
    biography = extract_biography(html)
    thumbnails = extract_thumbnail_urls(html)
    total_images = extract_total_images(html)
    page_count = extract_page_count(html)

    # Fetch additional image pages if needed (up to max_image_pages)
    if page_count > 1 and max_image_pages > 1:
        for page in range(2, min(page_count + 1, max_image_pages + 1)):
            page_url = f"{BASE_URL}/icon-{icon_id}-{page}"
            page_html = fetch_page(page_url)
            if page_html:
                thumbnails.extend(extract_thumbnail_urls(page_html))
            time.sleep(0.5)

    return {
        "icon_id": icon_id,
        "feast_days": feast_days,
        "keywords": keywords,
        "biography": biography,
        "thumbnails": thumbnails,
        "total_images": total_images,
        "page_count": page_count,
    }


def save_data(data: dict, path: str):
    entries = [data[k] for k in sorted(data.keys())]
    with open(path, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)


def main():
    parser = argparse.ArgumentParser(description="Scrape pravicon.com icon details")
    parser.add_argument("--index", type=str, default=None, help="Input index JSON")
    parser.add_argument("--output", type=str, default=None, help="Output details JSON")
    parser.add_argument("--delay", type=float, default=1.0, help="Seconds between requests")
    parser.add_argument("--max-image-pages", type=int, default=3,
                        help="Max image pages to fetch per icon (default 3)")
    parser.add_argument("--start-from", type=int, default=0,
                        help="Start from this icon_id (for resuming)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    if args.index is None:
        args.index = os.path.join(script_dir, "data", "pravicon_index.json")
    if args.output is None:
        args.output = os.path.join(script_dir, "data", "pravicon_details.json")

    # Load index
    with open(args.index, "r", encoding="utf-8") as f:
        index = json.load(f)
    print(f"Loaded index with {len(index)} entries")

    # Load existing details for resuming
    existing: dict[int, dict] = {}
    if os.path.exists(args.output):
        with open(args.output, "r", encoding="utf-8") as f:
            for entry in json.load(f):
                existing[entry["icon_id"]] = entry
        print(f"Loaded {len(existing)} existing detail entries")

    all_data = dict(existing)
    scraped_count = 0
    skipped_count = 0
    total = len(index)

    try:
        for i, entry in enumerate(index):
            icon_id = entry["icon_id"]

            if icon_id < args.start_from:
                continue

            if icon_id in existing and "error" not in existing[icon_id]:
                skipped_count += 1
                continue

            print(f"[{i + 1}/{total}] icon-{icon_id} ({entry['name']}) ...", end=" ", flush=True)

            result = scrape_icon_detail(icon_id, args.max_image_pages)
            # Merge name and category from index
            result["name"] = entry["name"]
            result["category"] = entry["category"]
            all_data[icon_id] = result

            thumb_count = len(result.get("thumbnails", []))
            print(f"images={thumb_count}/{result.get('total_images', 0)} "
                  f"keywords={len(result.get('keywords', []))} "
                  f"feast_days={result.get('feast_days', [])}")

            scraped_count += 1
            if args.delay > 0:
                time.sleep(args.delay)

            # Save every 50 entries
            if scraped_count % 50 == 0:
                save_data(all_data, args.output)
                print(f"  [saved {len(all_data)} entries]")

    except KeyboardInterrupt:
        print("\nInterrupted! Saving progress...")
    finally:
        save_data(all_data, args.output)

    print(f"\nDone. Scraped {scraped_count}, skipped {skipped_count}.")
    print(f"Total entries: {len(all_data)}")
    print(f"Saved to: {args.output}")

    # Stats
    with_images = sum(1 for d in all_data.values() if d.get("thumbnails"))
    with_bio = sum(1 for d in all_data.values() if d.get("biography"))
    total_thumbs = sum(len(d.get("thumbnails", [])) for d in all_data.values())
    print(f"\nStats:")
    print(f"  Entries with images:    {with_images}/{len(all_data)}")
    print(f"  Entries with biography: {with_bio}/{len(all_data)}")
    print(f"  Total thumbnails:       {total_thumbs}")


if __name__ == "__main__":
    main()
