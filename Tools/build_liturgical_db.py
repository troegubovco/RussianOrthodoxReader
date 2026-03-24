#!/usr/bin/env python3
"""
Build a bundled liturgical SQLite database from scraped Azbyka data.

Reads the scraped JSON (one full year) and produces a SQLite database with:
  - fixed_saints: keyed by (month, day), stores saints for each Gregorian date
  - moveable_cycle: keyed by pascha_offset (days from Pascha), stores readings/tone/fasting

Usage:
    python3 Tools/build_liturgical_db.py [--input Tools/data/liturgical_2025.json] [--year 2025]
"""
import argparse
import json
import os
import sqlite3
from datetime import date, timedelta


def pascha_date(year: int) -> date:
    """Compute Orthodox Pascha (Easter) for the given year — same algorithm as PaschalCalculator.swift."""
    a = year % 4
    b = year % 7
    c = year % 19
    d = (19 * c + 15) % 30
    e = (2 * a + 4 * b - d + 34) % 7
    month = (d + e + 114) // 31
    day = ((d + e + 114) % 31) + 1
    # Julian to Gregorian offset
    century = year // 100
    offset = century - century // 4 - 2
    # Build the date (Python handles overflow, e.g. April 36 → May 6)
    julian = date(year, month, day)
    return julian + timedelta(days=offset)


def main():
    parser = argparse.ArgumentParser(description="Build liturgical SQLite from scraped JSON")
    parser.add_argument("--input", type=str, default=None)
    parser.add_argument("--year", type=int, default=2025)
    parser.add_argument("--output", type=str, default=None)
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)

    if args.input is None:
        args.input = os.path.join(script_dir, "data", f"liturgical_{args.year}.json")
    if args.output is None:
        args.output = os.path.join(
            project_root, "RussianOrthodoxReader", "Resources", "Bible", "liturgical_calendar.sqlite"
        )

    with open(args.input, "r", encoding="utf-8") as f:
        data = json.load(f)
    print(f"Loaded {len(data)} days from {args.input}")

    # Load supplemental data files (e.g., Dec 2024 for extended negative offsets)
    supplemental_files = [
        os.path.join(script_dir, "data", "liturgical_2024_dec.json"),
    ]
    for sup_file in supplemental_files:
        if os.path.exists(sup_file):
            with open(sup_file, "r", encoding="utf-8") as f:
                sup_data = json.load(f)
            data.extend(sup_data)
            print(f"Loaded {len(sup_data)} supplemental days from {sup_file}")

    pascha = pascha_date(args.year)
    print(f"Pascha {args.year}: {pascha.isoformat()}")

    # Build database
    if os.path.exists(args.output):
        os.remove(args.output)

    conn = sqlite3.connect(args.output)
    cur = conn.cursor()

    cur.execute("""
        CREATE TABLE fixed_saints (
            month INTEGER NOT NULL,
            day INTEGER NOT NULL,
            saints_json TEXT NOT NULL,
            PRIMARY KEY (month, day)
        )
    """)

    cur.execute("""
        CREATE TABLE moveable_cycle (
            pascha_offset INTEGER PRIMARY KEY,
            apostol_display TEXT,
            gospel_display TEXT,
            other_readings_json TEXT,
            tone INTEGER,
            fasting TEXT,
            summary_title TEXT
        )
    """)

    cur.execute("CREATE INDEX idx_fixed_saints ON fixed_saints(month, day)")

    saints_count = 0
    readings_count = 0
    errors = 0

    for entry in data:
        if "error" in entry:
            errors += 1
            continue

        d = date.fromisoformat(entry["date"])
        offset = (d - pascha).days

        # ── Fixed saints (by Gregorian month-day) ──
        saints = entry.get("saints", [])
        if saints:
            cur.execute(
                "INSERT OR REPLACE INTO fixed_saints (month, day, saints_json) VALUES (?, ?, ?)",
                (d.month, d.day, json.dumps(saints, ensure_ascii=False)),
            )
            saints_count += 1

        # ── Moveable cycle (by Pascha offset) ──
        readings = entry.get("readings", [])
        apostol = next((r["display"] for r in readings if r.get("source") == "apostol"), None)
        gospel = next((r["display"] for r in readings if r.get("source") == "gospel"), None)

        # Collect non-apostol/gospel readings
        other = [r for r in readings if r.get("source") not in ("apostol", "gospel")]
        other_json = json.dumps(other, ensure_ascii=False) if other else None

        cur.execute(
            """INSERT OR REPLACE INTO moveable_cycle
               (pascha_offset, apostol_display, gospel_display, other_readings_json,
                tone, fasting, summary_title)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (
                offset,
                apostol,
                gospel,
                other_json,
                entry.get("tone"),
                entry.get("fasting"),
                entry.get("summary_title"),
            ),
        )
        if apostol or gospel:
            readings_count += 1

    conn.commit()

    # Print stats
    cur.execute("SELECT COUNT(*) FROM fixed_saints")
    total_saints = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM moveable_cycle")
    total_moveable = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM moveable_cycle WHERE apostol_display IS NOT NULL OR gospel_display IS NOT NULL")
    with_readings = cur.fetchone()[0]
    cur.execute("SELECT MIN(pascha_offset), MAX(pascha_offset) FROM moveable_cycle")
    min_off, max_off = cur.fetchone()

    conn.close()

    print(f"\nDatabase built: {args.output}")
    print(f"  Fixed saints entries:     {total_saints}")
    print(f"  Moveable cycle entries:   {total_moveable}")
    print(f"  Pascha offset range:      {min_off} to {max_off}")
    print(f"  Days with apostol/gospel: {with_readings}")
    print(f"  Errors (skipped):         {errors}")

    # Verify with a sample lookup
    print(f"\n── Sample lookups (using {args.year} Pascha = {pascha}) ──")
    conn = sqlite3.connect(args.output)
    cur = conn.cursor()

    for test_offset, label in [(0, "Pascha"), (1, "Pascha+1"), (7, "Thomas Sunday"), (49, "Pentecost"), (-48, "Lent start")]:
        cur.execute("SELECT apostol_display, gospel_display, tone, summary_title FROM moveable_cycle WHERE pascha_offset = ?", (test_offset,))
        row = cur.fetchone()
        test_date = pascha + timedelta(days=test_offset)
        if row:
            print(f"  {label:15s} ({test_date}): apostol={row[0] or '—'}, gospel={row[1] or '—'}, tone={row[2]}, title={row[3]}")
        else:
            print(f"  {label:15s} ({test_date}): NO DATA")

    conn.close()


if __name__ == "__main__":
    main()
