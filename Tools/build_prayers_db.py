#!/usr/bin/env python3
"""
Build the bundled prayers database from scraped/curated JSON.

Inputs:
  Tools/data/molitvoslov_raw.json    — output of scrape_molitvoslov.py
  Tools/data/prayer_templates.json   — optional manual curation: overrides/additions
                                       for имярек prayers with [[NAMES]] / [[V|m:…|f:…|pl:…]]
                                       tokens plus takes_names/name_case/name_list.
Output:
  RussianOrthodoxReader/Resources/prayers.sqlite

Usage:
    python3 Tools/build_prayers_db.py
"""
import json
import os
import re
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
RAW_PATH = os.path.join(SCRIPT_DIR, "data", "molitvoslov_raw.json")
TEMPLATES_PATH = os.path.join(SCRIPT_DIR, "data", "prayer_templates.json")
SUBTITLES_PATH = os.path.join(SCRIPT_DIR, "data", "prayer_subtitles.json")
DB_PATH = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "prayers.sqlite")

STRESS = "́"
VARIANT_RE = re.compile(r"\[\[V\|m:[^|\]]+\|f:[^|\]]+\|pl:[^\]]+\]\]")
NAMES_RE = re.compile(r"\[\[NAMES\]\]")
TOKEN_RE = re.compile(r"\[\[")


def search_normalize(text: str) -> str:
    """Lowercase, drop stress marks and template tokens, collapse whitespace,
    ё→е — so plain user queries match the accented civil-font text."""
    text = VARIANT_RE.sub(" ", NAMES_RE.sub(" ", text))
    text = text.replace(STRESS, "").replace("ё", "е").replace("Ё", "Е")
    text = text.lower()
    text = re.sub(r"[*\[\]]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def validate_template(slug: str, text: str) -> list[str]:
    """Every [[ opener must belong to a well-formed token; [[NAMES]] required."""
    problems = []
    stripped = VARIANT_RE.sub("", NAMES_RE.sub("", text))
    if TOKEN_RE.search(stripped):
        problems.append(f"{slug}: malformed [[…]] token")
    if not NAMES_RE.search(text):
        problems.append(f"{slug}: takes_names prayer has no [[NAMES]] token")
    return problems


def main() -> int:
    with open(RAW_PATH, encoding="utf-8") as f:
        raw = json.load(f)

    templates = {"prayers": []}
    if os.path.exists(TEMPLATES_PATH):
        with open(TEMPLATES_PATH, encoding="utf-8") as f:
            templates = json.load(f)
    template_by_slug = {p["slug"]: p for p in templates.get("prayers", [])}

    subtitles: dict[str, str] = {}
    if os.path.exists(SUBTITLES_PATH):
        with open(SUBTITLES_PATH, encoding="utf-8") as f:
            subtitles = {k: v for k, v in json.load(f).items() if not k.startswith("_")}

    def subtitle_for(slug: str, existing: str | None) -> str | None:
        if existing:
            return existing
        if slug in subtitles:
            return subtitles[slug]
        # Дубли «-2» в Последовании и благодарственных — женские формы текста;
        # в остальных категориях «-2» — просто повтор с другой страницы.
        if slug.endswith("-2") and slug[:-2] in subtitles:
            base = subtitles[slug[:-2]]
            if slug.startswith(("communion.", "thanksgiving.")):
                return base + " · женская форма"
            return base
        return None

    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.executescript("""
        CREATE TABLE categories (
            id          INTEGER PRIMARY KEY,
            slug        TEXT UNIQUE NOT NULL,
            title       TEXT NOT NULL,
            subtitle    TEXT,
            icon        TEXT,
            sort_order  INTEGER NOT NULL,
            parent_id   INTEGER,
            is_sequence INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE prayers (
            id          INTEGER PRIMARY KEY,
            category_id INTEGER NOT NULL REFERENCES categories(id),
            slug        TEXT UNIQUE NOT NULL,
            title       TEXT NOT NULL,
            subtitle    TEXT,
            sort_order  INTEGER NOT NULL,
            text_cs     TEXT NOT NULL,
            text_ru     TEXT,
            takes_names INTEGER NOT NULL DEFAULT 0,
            name_case   TEXT,
            name_list   TEXT,
            source_url  TEXT,
            title_plain TEXT NOT NULL DEFAULT '',
            search_text TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX idx_prayers_category ON prayers(category_id, sort_order);
    """)

    # Категории-последования читаются подряд, как в печатном молитвослове.
    SEQUENCE_CATEGORIES = {"morning", "evening", "communion", "thanksgiving"}

    cat_ids: dict[str, int] = {}
    for cat in raw["categories"]:
        parent_id = cat_ids.get(cat["parent"]) if cat.get("parent") else None
        if cat.get("parent") and parent_id is None:
            print(f"  ! категория {cat['slug']}: родитель {cat['parent']} не найден "
                  "(родители должны идти в конфиге раньше детей)")
        cur.execute(
            "INSERT INTO categories (slug, title, subtitle, icon, sort_order, parent_id, is_sequence) "
            "VALUES (?,?,?,?,?,?,?)",
            (cat["slug"], cat["title"], cat.get("subtitle"), cat.get("icon"),
             cat["sort_order"], parent_id, int(cat["slug"] in SEQUENCE_CATEGORIES)))
        cat_ids[cat["slug"]] = cur.lastrowid

    # Categories that exist only in the curated templates file (e.g. помянник prayers)
    for cat in templates.get("categories", []):
        if cat["slug"] not in cat_ids:
            cur.execute(
                "INSERT INTO categories (slug, title, subtitle, icon, sort_order) VALUES (?,?,?,?,?)",
                (cat["slug"], cat["title"], cat.get("subtitle"), cat.get("icon"), cat["sort_order"]))
            cat_ids[cat["slug"]] = cur.lastrowid

    problems: list[str] = []
    inserted = set()

    def insert_prayer(p: dict):
        slug = p["slug"]
        if slug in inserted:
            problems.append(f"{slug}: duplicate slug")
            return
        cat = cat_ids.get(p["category_slug"])
        if cat is None:
            problems.append(f"{slug}: unknown category {p['category_slug']}")
            return
        text_cs = p["text_cs"].strip()
        if not text_cs:
            problems.append(f"{slug}: empty text_cs")
            return
        takes_names = int(p.get("takes_names", 0))
        if takes_names:
            problems.extend(validate_template(slug, text_cs))
            if p.get("text_ru"):
                problems.extend(validate_template(slug, p["text_ru"]))
            if p.get("name_case") not in ("gen", "acc"):
                problems.append(f"{slug}: takes_names without valid name_case")
        if re.search(r"[а-яё]\d", text_cs):
            problems.append(f"{slug}: glued footnote digit in text_cs")
        # Ремарка «Читается трижды…» стоит после молитвы и без указания
        # «эта» читается двусмысленно (к какой из частей относится).
        text_cs = text_cs.replace("*Читается трижды,", "*Эта молитва читается трижды,")
        text_ru = p.get("text_ru") or None
        if text_ru:
            text_ru = text_ru.replace("*Читается трижды,", "*Эта молитва читается трижды,")
        title_plain = search_normalize(p["title"])
        search_text = search_normalize(
            " ".join(filter(None, [p["title"], p.get("subtitle"), text_cs, text_ru])))
        cur.execute(
            """INSERT INTO prayers (category_id, slug, title, subtitle, sort_order,
               text_cs, text_ru, takes_names, name_case, name_list, source_url,
               title_plain, search_text)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (cat, slug, p["title"], subtitle_for(slug, p.get("subtitle")), p["sort_order"], text_cs,
             text_ru, takes_names, p.get("name_case"),
             p.get("name_list"), p.get("source_url"), title_plain, search_text))
        inserted.add(slug)

    # Curated (template) prayers always sort ahead of scraped ones inside a
    # shared category — offset every scraped sort_order by a large constant so
    # the small curated sort_orders (1..N) lead. Relative order within a
    # purely-scraped category is preserved.
    SCRAPED_SORT_OFFSET = 1000
    for p in raw["prayers"]:
        override = template_by_slug.pop(p["slug"], None)
        if override:
            insert_prayer({**p, **override})
        else:
            insert_prayer({**p, "sort_order": p["sort_order"] + SCRAPED_SORT_OFFSET})
    # Remaining templates are standalone curated prayers
    for p in template_by_slug.values():
        insert_prayer(p)

    conn.commit()

    # ── Report ──
    print(f"Built {DB_PATH}")
    for slug, cid in cat_ids.items():
        n = cur.execute("SELECT COUNT(*) FROM prayers WHERE category_id=?", (cid,)).fetchone()[0]
        print(f"  {slug}: {n} prayers")
    total, with_ru, with_names = cur.execute(
        "SELECT COUNT(*), COUNT(text_ru), SUM(takes_names) FROM prayers").fetchone()
    stressed = cur.execute(
        "SELECT COUNT(*) FROM prayers WHERE text_cs LIKE '%' || char(769) || '%'").fetchone()[0]
    print(f"  total={total}, with_ru={with_ru}, takes_names={with_names or 0}, "
          f"with_stress={stressed}")

    if problems:
        print("\nPROBLEMS:")
        for pr in problems:
            print("  !", pr)
        return 1
    print("  validation: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
