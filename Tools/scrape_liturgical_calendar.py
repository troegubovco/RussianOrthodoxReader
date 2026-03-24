#!/usr/bin/env python3
"""
Scrape Azbyka.ru liturgical calendar data for a full year.

Fetches each day's public page and extracts:
  - Saints of the day
  - Biblical readings (with section: Liturgy, Matins, etc.)
  - Tone (Глас)
  - Fasting description
  - Week name / summary title

Saves incrementally to a JSON file so the scrape can be resumed.

Usage:
    python3 Tools/scrape_liturgical_calendar.py [--year 2025] [--output Tools/data/liturgical_2025.json]
"""
import argparse
import gzip
import io
import json
import os
import re
import sys
import time
import urllib.request
from datetime import date, timedelta


# ── HTML Parsing Helpers ─────────────────────────────────────────────────────

def html_to_text(html: str) -> str:
    """Strip HTML tags and decode common entities."""
    entities = [
        ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", '"'), ("&apos;", "'"),
        ("&#039;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&laquo;", "«"),
        ("&raquo;", "»"), ("&ndash;", "–"), ("&mdash;", "—"),
        ("&hellip;", "…"), ("&minus;", "−"), ("&shy;", ""),
        ("\u00a0", " "),
    ]
    result = html
    for ent, rep in entities:
        result = result.replace(ent, rep)
    # Decode numeric entities
    result = re.sub(r"&#x([0-9A-Fa-f]+);", lambda m: chr(int(m.group(1), 16)), result)
    result = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), result)
    # Strip tags
    result = re.sub(r"<[^>]+>", " ", result)
    return re.sub(r"\s+", " ", result).strip()


def slice_html(html: str, after: str, before: str) -> str | None:
    idx = html.find(after)
    if idx < 0:
        return None
    rest = html[idx + len(after):]
    end = rest.find(before)
    if end < 0:
        return None
    return rest[:end]


# ── Extraction Functions ─────────────────────────────────────────────────────

def extract_week_name(html: str) -> str | None:
    m = re.search(
        r'(?s)<div class="day__post-wp[^"]*">.*?<div class="shadow">.*?'
        r'<div class="lc">&nbsp;</div>(.*?)<div class="rc">&nbsp;</div>',
        html,
    )
    if not m:
        return None
    text = html_to_text(m.group(1))
    return text if text else None


def extract_tone(info_text: str) -> int | None:
    m = re.search(r"Глас\s+(\d+)", info_text)
    return int(m.group(1)) if m else None


def extract_fasting(info_text: str) -> str | None:
    for kw in ["Строгий пост", "Постный день", "Разрешается рыба", "Разрешается елей"]:
        if kw.lower() in info_text.lower():
            return kw
    return None


def extract_saints(html: str) -> list[str]:
    return [
        html_to_text(m.group(1))
        for m in re.finditer(r'(?s)<li class="ideograph-[^"]*">(.*?)</li>', html)
        if html_to_text(m.group(1))
    ]


# Section markers used in reading preambles
SECTION_MARKERS = [
    ("на 6-м часе", "6th_hour"),
    ("на 3-м часе", "3rd_hour"),
    ("на 9-м часе", "9th_hour"),
    ("на 1-м часе", "1st_hour"),
    ("на веч", "vespers"),
    ("повечер", "compline"),
    ("утр", "matins"),
    ("лит", "liturgy"),
]


def last_section_in(text: str) -> str | None:
    lowered = text.lower()
    best_pos, best_section = -1, None
    for marker, section in SECTION_MARKERS:
        idx = lowered.rfind(marker)
        if idx > best_pos:
            best_pos = idx
            best_section = section
    return best_section


def extract_readings(html: str) -> list[dict]:
    """
    Extract biblical readings from the page HTML.

    Strategy:
    1. Find the readings section (readings-text div or chteniya div)
    2. Look for <a class="bibref"> links inside <p> tags
    3. Classify each link by surrounding section marker text
    """
    # Strategy 1: Look inside readings-text div
    readings_section = slice_html(html, '<div class="readings-text">', '<div class="scripture-sub">')
    if readings_section is None:
        # Broader fallback: readings-text to end of readings-inner
        readings_section = slice_html(html, '<div class="readings-text">', '</div>\n            </div>\n</div>')

    if readings_section is None:
        # Strategy 2: Look in the chteniya section more broadly
        readings_section = slice_html(html, '<div id="chteniya"', '<div id="bogosluzhenija"')

    if readings_section is None:
        # Strategy 3: Look in audio player section (Bright Week)
        # Audio sections have bibref inside span.player-text
        readings_section = html  # Search entire page body

    # Find <p> elements containing bibref links
    p_with_refs = re.findall(
        r'(?s)<p[^>]*>(?:(?!</p>).)*?class="bibref".*?</p>',
        readings_section or "",
    )

    if not p_with_refs:
        # Try span.player-text sections (Bright Week audio player format)
        p_with_refs = re.findall(
            r'(?s)<span class="player-text">.*?</span>\s*</span>',
            readings_section or "",
        )

    if not p_with_refs:
        return []

    # Replace bibref links with markers for easier parsing
    combined = " ".join(p_with_refs)
    marked = re.sub(
        r'(?s)<a[^>]*class="bibref"[^>]*>(.*?)</a>',
        r"[[REF:\1]]",
        combined,
    )
    text = html_to_text(marked)

    readings = []
    current_section = None
    liturgy_index = 0
    cursor = 0

    for m in re.finditer(r"\[\[REF:(.*?)\]\]", text):
        preamble = text[cursor:m.start()]
        section = last_section_in(preamble)
        if section is not None:
            if section != current_section:
                liturgy_index = 0
            current_section = section

        ref_display = normalize_ref_display(m.group(1))
        if not ref_display:
            cursor = m.end()
            continue

        # Classify source
        if current_section == "liturgy":
            liturgy_index += 1
            if liturgy_index == 1:
                source = "apostol"
            elif liturgy_index == 2:
                source = "gospel"
            else:
                source = "liturgy"
        elif current_section:
            source = current_section
        else:
            source = ""

        readings.append({"source": source, "display": ref_display})
        cursor = m.end()

    # Post-process: if no section markers were found and we have exactly 2 readings
    # from the Feofan commentary, classify as apostol + gospel (standard pattern).
    if all(r["source"] == "" for r in readings) and len(readings) >= 2:
        # Check if first is likely Apostol (Acts, Epistles) and second is Gospel
        apostol_books = {"Деян", "Рим", "1Кор", "2Кор", "Гал", "Еф", "Флп", "Кол",
                         "1Сол", "2Сол", "1Тим", "2Тим", "Тит", "Флм", "Евр",
                         "Иак", "1Пет", "2Пет", "1Ин", "2Ин", "3Ин", "Иуд", "Откр"}
        gospel_books = {"Мф", "Мк", "Лк", "Ин"}
        first_book = readings[0]["display"].split()[0] if readings[0]["display"] else ""
        second_book = readings[1]["display"].split()[0] if readings[1]["display"] else ""
        if first_book in apostol_books or second_book in gospel_books:
            readings[0]["source"] = "apostol"
            readings[1]["source"] = "gospel"

    return readings


def normalize_ref_display(raw: str) -> str:
    """Clean up a reading reference display string."""
    value = html_to_text(raw)
    # Remove zachala references like (зач. 116)
    value = re.sub(r"\s*\(\s*зач[^)]*\)\.?", "", value)
    # Fix periods between book and chapter: "Деян.5" → "Деян 5"
    value = re.sub(r"(?<=\w)\.(?=\d)", " ", value)
    # Remove trailing periods
    value = re.sub(r"\.$", "", value)
    value = value.strip(" .,\n\t")
    return re.sub(r"\s+", " ", value).strip()


# ── Main Scraper ─────────────────────────────────────────────────────────────

def fetch_page(url: str, retries: int = 3) -> str | None:
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "RussianOrthodoxReader/1.0 (liturgical calendar builder)",
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Encoding": "gzip, deflate",
            })
            with urllib.request.urlopen(req, timeout=20) as resp:
                raw = resp.read()
                # Handle gzip-encoded responses
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


def scrape_day(d: date) -> dict:
    """Scrape a single day from Azbyka and return structured data."""
    url = f"https://azbyka.ru/days/{d.isoformat()}"
    html = fetch_page(url)
    if html is None:
        return {"date": d.isoformat(), "error": "fetch_failed"}

    # Extract the main content area (day section)
    day_section = slice_html(html, '<div class="text day__text">', '<div id="chteniya"') or ""
    info_text = ""
    p_match = re.search(r"(?s)<p>\s*(.*?)\s*</p>", day_section)
    if p_match:
        info_text = html_to_text(p_match.group(1))

    summary_title = extract_week_name(html)
    saints = extract_saints(day_section if day_section else html)
    readings = extract_readings(html)
    tone = extract_tone(info_text)
    fasting = extract_fasting(info_text)

    # If we found no saints in the day section, try the whole page
    if not saints:
        saints = extract_saints(html)

    return {
        "date": d.isoformat(),
        "summary_title": summary_title,
        "saints": saints,
        "readings": readings,
        "tone": tone,
        "fasting": fasting,
    }


def main():
    parser = argparse.ArgumentParser(description="Scrape Azbyka liturgical calendar")
    parser.add_argument("--year", type=int, default=2025, help="Year to scrape")
    parser.add_argument("--output", type=str, default=None, help="Output JSON path")
    parser.add_argument("--delay", type=float, default=1.0, help="Seconds between requests")
    parser.add_argument("--start-month", type=int, default=1, help="Start from this month (for resuming)")
    parser.add_argument("--start-day", type=int, default=1, help="Start from this day (for resuming)")
    args = parser.parse_args()

    if args.output is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        os.makedirs(os.path.join(script_dir, "data"), exist_ok=True)
        args.output = os.path.join(script_dir, "data", f"liturgical_{args.year}.json")

    # Load existing data if resuming
    existing: dict[str, dict] = {}
    if os.path.exists(args.output):
        with open(args.output, "r", encoding="utf-8") as f:
            for entry in json.load(f):
                existing[entry["date"]] = entry
        print(f"Loaded {len(existing)} existing entries from {args.output}")

    start = date(args.year, args.start_month, args.start_day)
    end = date(args.year, 12, 31)
    current = start
    total_days = (end - start).days + 1
    scraped_count = 0
    skipped_count = 0

    print(f"Scraping {args.year}: {start} to {end} ({total_days} days)")

    all_data = dict(existing)  # Start with existing entries

    try:
        while current <= end:
            key = current.isoformat()
            if key in existing and "error" not in existing[key]:
                skipped_count += 1
                current += timedelta(days=1)
                continue

            day_num = (current - date(args.year, 1, 1)).days + 1
            print(f"[{day_num:3d}/365] {key} ...", end=" ", flush=True)

            result = scrape_day(current)
            all_data[key] = result

            r_count = len(result.get("readings", []))
            s_count = len(result.get("saints", []))
            print(f"saints={s_count} readings={r_count} tone={result.get('tone')} fasting={result.get('fasting')}")

            scraped_count += 1
            current += timedelta(days=1)

            if args.delay > 0:
                time.sleep(args.delay)

            # Save every 10 days for safety
            if scraped_count % 10 == 0:
                save_data(all_data, args.output)

    except KeyboardInterrupt:
        print("\nInterrupted! Saving progress...")
    finally:
        save_data(all_data, args.output)

    print(f"\nDone. Scraped {scraped_count}, skipped {skipped_count} (already had).")
    print(f"Total entries: {len(all_data)}")
    print(f"Saved to: {args.output}")

    # Print summary stats
    total_readings = sum(len(d.get("readings", [])) for d in all_data.values())
    total_saints = sum(len(d.get("saints", [])) for d in all_data.values())
    days_with_readings = sum(1 for d in all_data.values() if d.get("readings"))
    days_with_saints = sum(1 for d in all_data.values() if d.get("saints"))
    print(f"\nStats:")
    print(f"  Days with readings: {days_with_readings}/{len(all_data)}")
    print(f"  Days with saints:   {days_with_saints}/{len(all_data)}")
    print(f"  Total readings:     {total_readings}")
    print(f"  Total saints:       {total_saints}")


def save_data(data: dict, path: str):
    sorted_entries = [data[k] for k in sorted(data.keys())]
    with open(path, "w", encoding="utf-8") as f:
        json.dump(sorted_entries, f, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
