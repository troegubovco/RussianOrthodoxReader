#!/usr/bin/env python3
"""Step 10 — Build icon_meta.sqlite: the content database bundled in the app.

One row per pravicon subject (all ~3,150, so k-NN suggestions always resolve
to a name), with:
  - lives      — saint biography, SHARED across all icons of that saint
  - histories  — history of the icon type (theotokos/christ/angels subjects)
  - prayers    — тропарь/кондак/молитва/величание per subject
Content priority: azbyka.ru scrape (full texts) > pravicon biography (short).

Usage:
    .venv/bin/python 10_build_meta_db.py
Output:
    work/icon_meta.sqlite  ->  copy to RussianOrthodoxReader/Resources/Icons/
"""
from __future__ import annotations

import argparse
import datetime
import json
import sqlite3
from pathlib import Path

from common import (AZBYKA_CONTENT_JSON, AZBYKA_MATCH_CSV, DETAILS_JSON,
                    LABELS_JSON, META_DB)

SCHEMA = """
CREATE TABLE subjects (
    icon_id         INTEGER PRIMARY KEY,   -- pravicon id, same as icons.sqlite
    name            TEXT NOT NULL,
    category        TEXT NOT NULL,         -- saints | theotokos | christ | angels
    label_index     INTEGER,               -- classifier output index; NULL if not a class
    feast_days_json TEXT,
    keywords_csv    TEXT,
    pravicon_url    TEXT,
    azbyka_url      TEXT
);
CREATE TABLE lives (
    icon_id INTEGER PRIMARY KEY REFERENCES subjects(icon_id),
    life    TEXT NOT NULL,
    source  TEXT NOT NULL                  -- 'azbyka' | 'pravicon'
);
CREATE TABLE histories (
    icon_id INTEGER PRIMARY KEY REFERENCES subjects(icon_id),
    history TEXT NOT NULL,
    source  TEXT NOT NULL
);
CREATE TABLE prayers (
    prayer_id INTEGER PRIMARY KEY AUTOINCREMENT,
    icon_id   INTEGER NOT NULL REFERENCES subjects(icon_id),
    kind      TEXT NOT NULL,               -- Тропарь / Кондак / Молитва / Величание / …
    glas      TEXT,
    body      TEXT NOT NULL,
    position  INTEGER DEFAULT 0,
    source    TEXT NOT NULL DEFAULT 'azbyka'
);
CREATE INDEX idx_prayers_icon ON prayers(icon_id);
CREATE INDEX idx_subjects_label ON subjects(label_index);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=str(META_DB))
    args = parser.parse_args()

    with open(DETAILS_JSON, encoding="utf-8") as f:
        details = [e for e in json.load(f) if e.get("icon_id") and not e.get("error")]

    label_index: dict[int, int] = {}
    if LABELS_JSON.exists():
        with open(LABELS_JSON, encoding="utf-8") as f:
            for c in json.load(f)["classes"]:
                label_index[c["icon_id"]] = c["index"]
    else:
        print("WARNING: work/labels.json not found — label_index will be empty")

    azbyka: dict[str, dict] = {}
    if AZBYKA_CONTENT_JSON.exists():
        with open(AZBYKA_CONTENT_JSON, encoding="utf-8") as f:
            azbyka = json.load(f)
    else:
        print("WARNING: no azbyka content yet — using short pravicon texts only")

    azbyka_urls: dict[int, str] = {}
    if AZBYKA_MATCH_CSV.exists():
        import csv
        with open(AZBYKA_MATCH_CSV, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                if r.get("status") in ("ok", "manual") and r.get("url"):
                    azbyka_urls[int(r["icon_id"])] = r["url"]

    out = Path(args.output)
    if out.exists():
        out.unlink()
    out.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(out)
    conn.executescript(SCHEMA)

    n_lives = n_hist = n_prayers = 0
    for e in details:
        icon_id = e["icon_id"]
        category = e.get("category", "")
        conn.execute(
            "INSERT INTO subjects VALUES (?,?,?,?,?,?,?,?)",
            (icon_id, e.get("name", ""), category,
             label_index.get(icon_id),
             json.dumps(e.get("feast_days", []), ensure_ascii=False),
             ", ".join(e.get("keywords", [])),
             f"https://pravicon.com/icon-{icon_id}",
             azbyka_urls.get(icon_id)))

        az = azbyka.get(str(icon_id), {})
        pravicon_bio = (e.get("biography") or "").strip()

        if category == "saints":
            life = az.get("life") or pravicon_bio
            if life and len(life) > 60:
                conn.execute("INSERT INTO lives VALUES (?,?,?)",
                             (icon_id, life, "azbyka" if az.get("life") else "pravicon"))
                n_lives += 1
        else:
            history = az.get("history") or pravicon_bio
            if history and len(history) > 60:
                conn.execute("INSERT INTO histories VALUES (?,?,?)",
                             (icon_id, history,
                              "azbyka" if az.get("history") else "pravicon"))
                n_hist += 1

        for p in az.get("prayers", []):
            conn.execute(
                "INSERT INTO prayers (icon_id, kind, glas, body, position) "
                "VALUES (?,?,?,?,?)",
                (icon_id, p["kind"], p.get("glas", ""), p["body"], p.get("position", 0)))
            n_prayers += 1

    conn.execute("INSERT INTO meta VALUES ('generated', ?)",
                 (datetime.datetime.now(datetime.timezone.utc).isoformat(),))
    conn.execute("INSERT INTO meta VALUES ('num_classes', ?)", (str(len(label_index)),))
    conn.commit()

    # Coverage over classifier classes — the ones users will actually hit.
    missing_text, missing_prayers = [], []
    for icon_id in label_index:
        has_text = conn.execute(
            "SELECT 1 FROM lives WHERE icon_id=? UNION SELECT 1 FROM histories "
            "WHERE icon_id=?", (icon_id, icon_id)).fetchone()
        has_prayer = conn.execute(
            "SELECT 1 FROM prayers WHERE icon_id=? LIMIT 1", (icon_id,)).fetchone()
        name = conn.execute("SELECT name FROM subjects WHERE icon_id=?",
                            (icon_id,)).fetchone()[0]
        if not has_text:
            missing_text.append(name)
        if not has_prayer:
            missing_prayers.append(name)

    conn.close()
    size_mb = out.stat().st_size / 1e6
    print(f"Built {out} ({size_mb:.1f} MB): {len(details)} subjects, "
          f"{n_lives} lives, {n_hist} histories, {n_prayers} prayers")
    if label_index:
        nc = len(label_index)
        print(f"Classifier-class coverage: text {nc - len(missing_text)}/{nc}, "
              f"prayers {nc - len(missing_prayers)}/{nc}")
        for name in missing_text[:15]:
            print(f"  no text:    {name}")
        for name in missing_prayers[:15]:
            print(f"  no prayers: {name}")


if __name__ == "__main__":
    main()
