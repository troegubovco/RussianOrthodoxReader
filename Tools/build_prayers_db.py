#!/usr/bin/env python3
"""
Build the bundled prayers database from scraped/curated JSON.

Inputs:
  Tools/data/molitvoslov_raw.json    — output of scrape_molitvoslov.py
  Tools/data/prayer_templates.json   — optional manual curation: overrides/additions
                                       for имярек prayers with [[NAMES]] / [[V|m:…|f:…|pl:…]]
                                       tokens plus takes_names/name_case/name_list.
Output:
  Shared/prayers.sqlite

Usage:
    python3 Tools/build_prayers_db.py
"""
import hashlib
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
# Ручные правки заголовков (и при необходимости подзаголовков) поверх
# заголовков со страниц azbyka: slug → {"title": …, "subtitle": …(опц.)}.
TITLE_OVERRIDES_PATH = os.path.join(SCRIPT_DIR, "data", "prayer_title_overrides.json")
# Поиск (search_design.md §3.2/§3.3): ситуативные теги и модерн→церковнославянские синонимы.
TAGS_PATH = os.path.join(SCRIPT_DIR, "data", "prayer_tags.json")
SYNONYMS_PATH = os.path.join(SCRIPT_DIR, "data", "prayer_synonyms.json")
# Русские переводы, не покрытые text_ru в molitvoslov_raw.json/prayer_templates.json —
# см. Tools/data/prayer_translations.json:_comment. Кафизмы Псалтири собираются
# отдельно build_psalter_ru.py (текст псалмов из Синодального перевода); их
# завершающие тропари/молитва берутся из TRANSLATIONS_PATH по ключу "<slug>.tail",
# либо остаются на церковнославянском, если перевод ещё не готов.
TRANSLATIONS_PATH = os.path.join(SCRIPT_DIR, "data", "prayer_translations.json")
BIBLE_DB_PATH = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "Bible", "rus_synodal.sqlite")
DB_PATH = os.path.join(PROJECT_ROOT, "Shared", "prayers.sqlite")

sys.path.insert(0, SCRIPT_DIR)
from russian_stemmer import stem  # noqa: E402  (must stay in sync with Shared/RussianStemmer.swift)
# Латинские буквы-двойники внутри кириллических слов (опечатки azbyka: «Тво́pче»)
# — чинятся при сборке для ВСЕХ молитв, в т.ч. давно отскрейпленных.
from scrape_molitvoslov import fix_latin_cyrillic_confusables  # noqa: E402
from build_psalter_ru import build_kathisma_translations, TAIL_RE as KATHISMA_TAIL_RE  # noqa: E402

KATHISMA_SLUG_RE = re.compile(r"^psaltir\.kafizma-(\d+)$")

STRESS = "́"
VARIANT_RE = re.compile(r"\[\[V\|m:[^|\]]+\|f:[^|\]]+\|pl:[^\]]+\]\]")
NAMES_RE = re.compile(r"\[\[NAMES\]\]")
TOKEN_RE = re.compile(r"\[\[")
# Letters only (matches Swift SearchNormalizer.tokens: split on runs of Character.isLetter).
WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)

# Category priority for cross-category duplicate collapsing (search_design.md §3.5):
# the group's canonical row (dup_rank 0) is the one in the highest-priority category.
DUP_CATEGORY_PRIORITY = [
    "main", "bogorodice", "canons",
    "potreba-health", "potreba-path", "potreba-sorrow", "potreba-otechestvo",
    "pominovenie", "morning", "evening", "communion", "thanksgiving",
    "obihod", "family", "saints", "prazdniki", "communion-prep",
]

# Domain stopword stems shipped with the data (search_design.md §3.3), identical to
# Shared/SearchNormalizer.swift's `stopStems` constant — kept in sync by hand; both are
# small and reviewed together whenever either changes.
SEARCH_STOPWORD_STEMS = [
    "а", "в", "для", "есл", "же", "за", "и", "из", "к", "как", "когд",
    "на", "не", "но", "о", "об", "он", "от", "перед", "по", "при", "про",
    "с", "у", "что", "чтоб", "я",
    "молитв", "текст", "чита",
]


def index_stems(text: str | None) -> str:
    """Tokenise + stem free text for an FTS5 column: strip template tokens and
    stress, lowercase, ё→е, split into letter-runs, stem each. Mirrors
    Shared/SearchNormalizer.swift's tokens()+surfaceStem() pipeline, but this
    is BUILD-time indexing — see search_design.md §1 for why the index side
    never runs NLTagger or the conjugation map."""
    if not text:
        return ""
    t = VARIANT_RE.sub(" ", NAMES_RE.sub(" ", text))
    t = t.replace(STRESS, "").replace("ё", "е").replace("Ё", "Е").lower()
    return " ".join(stem(w) for w in WORD_RE.findall(t))


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


def build_search_index(conn, cur, cat_ids: dict, inserted: set, problems: list) -> dict:
    """Adds the search tables described in search_design.md §3.1 on top of the
    already-committed `prayers`/`categories` tables: `prayers_fts` (contentless
    FTS5 over stems), `category_tags`, `search_synonyms`, `search_stopwords`,
    and `dup_group`/`dup_rank` columns on `prayers`. Appends to `problems` (does
    not raise) for any tag/synonym referencing a slug or category that doesn't
    exist — the caller's final `if problems` check fails the build on those.
    """
    with open(TAGS_PATH, encoding="utf-8") as f:
        tags_raw = {k: v for k, v in json.load(f).items() if not k.startswith("_")}
    with open(SYNONYMS_PATH, encoding="utf-8") as f:
        synonyms_raw = {k: v for k, v in json.load(f).items() if not k.startswith("_")}

    category_tags: dict[int, str] = {}   # category_id -> raw tag string
    prayer_tags: dict[str, str] = {}     # prayer slug -> raw tag string
    for key, value in tags_raw.items():
        if key.startswith("cat:"):
            cat_slug = key[len("cat:"):]
            cid = cat_ids.get(cat_slug)
            if cid is None:
                problems.append(f"prayer_tags.json: unknown category '{cat_slug}'")
                continue
            category_tags[cid] = value
        else:
            if key not in inserted:
                problems.append(f"prayer_tags.json: unknown prayer slug '{key}'")
                continue
            prayer_tags[key] = value

    # Stem-mismatch warning (§3.2): flags a tag word whose stem differs from the
    # stem of its "+ом" inflection — a hint the curator should also list that
    # inflected form, not a hard error.
    all_tag_words: set[str] = set()
    for value in tags_raw.values():
        all_tag_words.update(value.split())
    for w in sorted(all_tag_words):
        s_word, s_infl = stem(w), stem(w + "ом")
        if s_word != s_infl:
            print(f"  ! tag word {w!r}: stem={s_word!r} but stem({w}ом)={s_infl!r} "
                  "— consider listing the inflected form too")

    # ── dup_group / dup_rank (§3.5): collapse cross-category & feminine-form dupes ──
    cur.execute("ALTER TABLE prayers ADD COLUMN dup_group TEXT")
    cur.execute("ALTER TABLE prayers ADD COLUMN dup_rank INTEGER NOT NULL DEFAULT 0")

    def dup_priority(slug: str) -> int:
        cat_slug = slug.split(".", 1)[0]
        return DUP_CATEGORY_PRIORITY.index(cat_slug) if cat_slug in DUP_CATEGORY_PRIORITY else 999

    def norm_for_hash(text: str) -> str:
        return re.sub(r"\s+", " ", text.replace(STRESS, "")).strip().lower()

    hash_groups: dict[str, list[tuple[int, str]]] = {}
    for pid, slug, text_cs in cur.execute("SELECT id, slug, text_cs FROM prayers").fetchall():
        h = hashlib.sha1(norm_for_hash(text_cs).encode("utf-8")).hexdigest()[:16]
        hash_groups.setdefault(h, []).append((pid, slug))

    dup_groups = dup_rows = 0
    for h, members in hash_groups.items():
        if len(members) < 2:
            continue
        dup_groups += 1
        dup_rows += len(members)
        members.sort(key=lambda m: dup_priority(m[1]))
        for rank, (pid, _slug) in enumerate(members):
            cur.execute("UPDATE prayers SET dup_group=?, dup_rank=? WHERE id=?", (h, rank, pid))

    # ── category_tags ──
    cur.execute("""
        CREATE TABLE category_tags (
            category_id INTEGER PRIMARY KEY REFERENCES categories(id),
            tags_s      TEXT NOT NULL
        )
    """)
    for cid, raw in category_tags.items():
        cur.execute("INSERT INTO category_tags (category_id, tags_s) VALUES (?,?)",
                     (cid, index_stems(raw)))

    # ── search_synonyms — modern → liturgical, stemmed both sides, query-side only ──
    cur.execute("""
        CREATE TABLE search_synonyms (
            term_stem      TEXT NOT NULL,
            expansion_stem TEXT NOT NULL,
            PRIMARY KEY (term_stem, expansion_stem)
        ) WITHOUT ROWID
    """)
    synonym_rows = 0
    for term, expansions in synonyms_raw.items():
        term_stem = stem(term.lower().replace("ё", "е"))
        for exp in expansions:
            exp_stem = stem(exp.lower().replace("ё", "е"))
            cur.execute(
                "INSERT OR IGNORE INTO search_synonyms (term_stem, expansion_stem) VALUES (?,?)",
                (term_stem, exp_stem))
            synonym_rows += 1

    # ── search_stopwords — ships with the data; mirror of SearchNormalizer.stopStems ──
    cur.execute("CREATE TABLE search_stopwords (stem TEXT PRIMARY KEY) WITHOUT ROWID")
    for s in SEARCH_STOPWORD_STEMS:
        cur.execute("INSERT OR IGNORE INTO search_stopwords (stem) VALUES (?)", (s,))

    # ── prayers_fts (contentless: rowid == prayers.id) ──
    cur.execute("""
        CREATE VIRTUAL TABLE prayers_fts USING fts5(
            title_s, subtitle_s, tags_s, cat_tags_s, text_s,
            content='',
            tokenize='unicode61 remove_diacritics 2'
        )
    """)
    prayer_rows = cur.execute("""
        SELECT id, slug, category_id, title, subtitle, text_cs, text_ru FROM prayers
    """).fetchall()
    for pid, slug, cid, title, subtitle, text_cs, text_ru in prayer_rows:
        title_s = index_stems(title)
        subtitle_s = index_stems(subtitle)
        tags_s = index_stems(prayer_tags.get(slug, ""))
        cat_tags_s = index_stems(category_tags.get(cid, ""))
        # akathist_psalter_design.md §7 A: the 20 kathismas are 150 psalms of
        # ЦС body text with no incremental search value — Bible search
        # already covers the psalms, and psaltir prayers are found by title/
        # tag ("кафизма", "псалтирь") same as anything else. Indexing their
        # bodies would be the single biggest contributor to prayers_fts size
        # for close to zero recall benefit, so text_s is titles/subtitle/tags
        # only for this one category.
        if slug.split(".", 1)[0] == "psaltir":
            text_s = ""
        else:
            text_s = " ".join(filter(None, [index_stems(text_cs), index_stems(text_ru)]))
        cur.execute(
            """INSERT INTO prayers_fts(rowid, title_s, subtitle_s, tags_s, cat_tags_s, text_s)
               VALUES (?,?,?,?,?,?)""",
            (pid, title_s, subtitle_s, tags_s, cat_tags_s, text_s))

    conn.commit()
    cur.execute("INSERT INTO prayers_fts(prayers_fts) VALUES ('optimize')")
    conn.commit()
    conn.execute("VACUUM")

    return {
        "tag_entries": len(tags_raw),
        "category_tags": len(category_tags),
        "prayer_tags": len(prayer_tags),
        "synonyms": synonym_rows,
        "dup_groups": dup_groups,
        "dup_rows": dup_rows,
        "db_size_mb": os.path.getsize(DB_PATH) / (1024 * 1024),
    }


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

    title_overrides: dict[str, dict] = {}
    if os.path.exists(TITLE_OVERRIDES_PATH):
        with open(TITLE_OVERRIDES_PATH, encoding="utf-8") as f:
            title_overrides = {k: v for k, v in json.load(f).items() if not k.startswith("_")}

    translations: dict[str, dict] = {}
    if os.path.exists(TRANSLATIONS_PATH):
        with open(TRANSLATIONS_PATH, encoding="utf-8") as f:
            translations = {k: v for k, v in json.load(f).items() if not k.startswith("_")}

    # Кафизмы Псалтири: text_ru = Синодальный текст псалмов кафизмы (собран из
    # rus_synodal.sqlite, read-only) + перевод завершающих тропарей/молитвы из
    # translations["psaltir.kafizma-N.tail"], если он уже готов, иначе — тот же
    # церковнославянский «хвост», что и в text_cs (переводчик работает отдельно).
    kathisma_ru_bodies: dict[str, str] = {}
    if os.path.exists(BIBLE_DB_PATH):
        kathisma_ru_bodies = build_kathisma_translations(BIBLE_DB_PATH, RAW_PATH)
    else:
        print(f"  ! {BIBLE_DB_PATH}: not found — psaltir.kafizma-N will keep text_ru=null")

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
            parent_id = cat_ids.get(cat["parent"]) if cat.get("parent") else None
            if cat.get("parent") and parent_id is None:
                print(f"  ! категория {cat['slug']}: родитель {cat['parent']} не найден "
                      "(родители должны идти в конфиге раньше детей)")
            cur.execute(
                "INSERT INTO categories (slug, title, subtitle, icon, sort_order, parent_id) "
                "VALUES (?,?,?,?,?,?)",
                (cat["slug"], cat["title"], cat.get("subtitle"), cat.get("icon"),
                 cat["sort_order"], parent_id))
            cat_ids[cat["slug"]] = cur.lastrowid

    problems: list[str] = []
    inserted = set()

    # Страницы azbyka иногда повторяют одну молитву дважды — вторую копию не берём.
    DROP_SLUGS = {
        "potreba-sorrow.molitva-pred-ikonoj-bozhiej-materi-pokrov-presvyatoj-bogorod-2",
    }

    def insert_prayer(p: dict):
        slug = p["slug"]
        if slug in DROP_SLUGS:
            return
        if slug in inserted:
            problems.append(f"{slug}: duplicate slug")
            return
        if slug in title_overrides:
            ov = title_overrides.pop(slug)
            p = {**p, "title": ov.get("title", p["title"])}
            if ov.get("subtitle"):
                p["subtitle"] = ov["subtitle"]
        cat = cat_ids.get(p["category_slug"])
        if cat is None:
            problems.append(f"{slug}: unknown category {p['category_slug']}")
            return
        kathisma_m = KATHISMA_SLUG_RE.match(slug)
        if kathisma_m and slug in kathisma_ru_bodies:
            tail_m = KATHISMA_TAIL_RE.search(p["text_cs"])
            cs_tail = p["text_cs"][tail_m.start():] if tail_m else ""
            tail_entry = translations.get(f"{slug}.tail")
            ru_tail = tail_entry["text_ru"] if tail_entry and tail_entry.get("text_ru") else cs_tail
            p = {**p, "text_ru": kathisma_ru_bodies[slug] + (("\n\n" + ru_tail) if ru_tail else "")}
        else:
            translated = translations.get(slug)
            if translated and translated.get("text_ru") and (not p.get("text_ru") or translated.get("override")):
                p = {**p, "text_ru": translated["text_ru"]}
        text_cs = fix_latin_cyrillic_confusables(p["text_cs"].strip())
        if p.get("text_ru"):
            p = {**p, "text_ru": fix_latin_cyrillic_confusables(p["text_ru"])}
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
        if re.search(r"[а-яёА-ЯЁ]́?\d", text_cs):
            problems.append(f"{slug}: glued footnote digit in text_cs")
        # Ремарка «Читается трижды…» стоит после молитвы и без указания
        # «эта» читается двусмысленно (к какой из частей относится).
        text_cs = text_cs.replace("*Читается трижды,", "*Эта молитва читается трижды,")
        text_ru = p.get("text_ru") or None
        if text_ru:
            text_ru = text_ru.replace("*Читается трижды,", "*Эта молитва читается трижды,")
        resolved_subtitle = subtitle_for(slug, p.get("subtitle"))
        title_plain = search_normalize(p["title"])
        search_text = search_normalize(
            " ".join(filter(None, [p["title"], resolved_subtitle, text_cs, text_ru])))
        cur.execute(
            """INSERT INTO prayers (category_id, slug, title, subtitle, sort_order,
               text_cs, text_ru, takes_names, name_case, name_list, source_url,
               title_plain, search_text)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (cat, slug, p["title"], resolved_subtitle, p["sort_order"], text_cs,
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

    for slug in title_overrides:
        problems.append(f"{slug}: title override for unknown prayer")
    for key in translations:
        base_slug = key[: -len(".tail")] if key.endswith(".tail") else key
        if base_slug not in inserted:
            problems.append(f"prayer_translations.json: unknown prayer slug '{key}'")
    conn.commit()

    # ── Search index (search_design.md §3.1–§3.5, steps 4–5) ──
    search_stats = build_search_index(conn, cur, cat_ids, inserted, problems)

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
    print(f"  search: {search_stats['tag_entries']} tags ({search_stats['category_tags']} cat: + "
          f"{search_stats['prayer_tags']} prayer), {search_stats['synonyms']} synonym rows, "
          f"{search_stats['dup_groups']} dup groups ({search_stats['dup_rows']} rows), "
          f"db size {search_stats['db_size_mb']:.2f} MB")

    if problems:
        print("\nPROBLEMS:")
        for pr in problems:
            print("  !", pr)
        return 1
    print("  validation: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
