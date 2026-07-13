#!/usr/bin/env python3
"""
Scrape Azbyka.ru молитвослов pages into structured JSON for build_prayers_db.py.

Two page kinds (declared per-page in Tools/data/molitvoslov_sources.json):
  - "parallel": a single <table class="adaptive"> where each prayer starts with
    an <h3> row, followed by two-column rows (left = ЦС гражданским шрифтом
    с ударениями, right = русский перевод) and full-width rubric/refrain rows.
  - "plain": article body with one <h2> per prayer; ЦС text in <p class="paint">
    paragraphs (footnote <sup> markers stripped); <p class="translate"> blocks
    are commentary, not translations — ignored.

Output entries: {category_slug, slug, title, sort_order, text_cs, text_ru?, source_url}
Rubric paragraphs (instructions, e.g. «Читается трижды…») are wrapped in
*asterisks* so the app can render them muted/italic.

Usage:
    python3 Tools/scrape_molitvoslov.py [--sources Tools/data/molitvoslov_sources.json]
                                        [--output Tools/data/molitvoslov_raw.json]
"""
import argparse
import gzip
import json
import os
import re
import sys
import time
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOURCES = os.path.join(SCRIPT_DIR, "data", "molitvoslov_sources.json")
DEFAULT_OUTPUT = os.path.join(SCRIPT_DIR, "data", "molitvoslov_raw.json")

STRESS = "́"  # combining acute accent


# ── Fetching (same etiquette as scrape_liturgical_calendar.py) ───────────────

def fetch_page(url: str, retries: int = 3) -> str | None:
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "RussianOrthodoxReader/1.0 (prayer book builder)",
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Encoding": "gzip, deflate",
            })
            with urllib.request.urlopen(req, timeout=20) as resp:
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


# ── HTML cleaning ────────────────────────────────────────────────────────────

ENTITIES = [
    ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", '"'), ("&apos;", "'"),
    ("&#039;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&laquo;", "«"),
    ("&raquo;", "»"), ("&ndash;", "–"), ("&mdash;", "—"),
    ("&hellip;", "…"), ("&minus;", "−"), ("&shy;", ""), (" ", " "),
]


def decode_entities(text: str) -> str:
    for ent, rep in ENTITIES:
        text = text.replace(ent, rep)
    text = re.sub(r"&#x([0-9A-Fa-f]+);", lambda m: chr(int(m.group(1), 16)), text)
    text = re.sub(r"&#(\d+);", lambda m: chr(int(m.group(1))), text)
    return text


def strip_footnotes(html: str) -> str:
    """Remove <sup>…</sup> footnote markers (azbyka glues digits onto words)."""
    return re.sub(r"<sup[^>]*>.*?</sup>", "", html, flags=re.S)


def inline_text(html: str) -> str:
    """Flatten inline markup to plain text (keeps link/emphasis inner text)."""
    html = strip_footnotes(html)
    html = re.sub(r"<br\s*/?>", "\n", html)
    html = re.sub(r"<[^>]+>", "", html)
    html = decode_entities(html)
    # Footnote digits glued to words outside <sup> («взе́мляй1»); numbers after
    # a space («Псалом 50») are untouched.
    html = re.sub(r"(?<=[а-яёА-ЯЁ])\d+", "", html)
    return re.sub(r"[ \t]+", " ", html).strip()


def is_rubric(par_html: str) -> bool:
    """A paragraph is a rubric only if the <strong> covers essentially all of it.
    Mixed paragraphs («<strong>Аще иерей:</strong> Благослове́н Бог…») stay normal."""
    if "<strong" not in par_html:
        return False
    full = inline_text(par_html)
    strong_text = " ".join(inline_text(s) for s in
                           re.findall(r"<strong[^>]*>(.*?)(?:</strong>|$)", par_html, re.S))
    remainder = full
    for chunk in strong_text.split():
        remainder = remainder.replace(chunk, "", 1)
    remainder = remainder.strip(" :.,—–-*()")
    return len(remainder) <= max(2, len(full) * 0.1)


def cell_paragraphs(cell_html: str) -> list[tuple[str, bool]]:
    """Split a table cell / section body into (text, is_rubric) paragraphs."""
    out: list[tuple[str, bool]] = []
    for m in re.finditer(r"<p\b[^>]*>(.*?)(?:</p>|(?=<p\b)|$)", cell_html, re.S):
        inner = m.group(1)
        text = inline_text(inner)
        if not text:
            continue
        out.append((text, is_rubric(inner)))
    if not out:
        text = inline_text(cell_html)
        if text:
            out.append((text, False))
    return out


def strip_stress(text: str) -> str:
    return text.replace(STRESS, "")


TITLE_FIXUPS = {
    "Тропари сия": "Тропари",
}


def reattach_intro_rubrics(prayers: list[dict]) -> None:
    """A rubric at the END of a prayer that ends with «:» introduces the NEXT
    prayer («…произноси следующие молитвы:») — move it to the next one's start.
    Mutates cs/ru paragraph lists in place."""
    for i in range(len(prayers) - 1):
        cur, nxt = prayers[i], prayers[i + 1]
        for key in ("cs", "ru"):
            paras = cur.get(key) or []
            if paras and paras[-1].startswith("*") and paras[-1].rstrip("*").rstrip().endswith(":"):
                nxt.setdefault(key, [])
                nxt[key].insert(0, paras.pop())


# ── Slugs ────────────────────────────────────────────────────────────────────

TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "j", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "shh",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def slugify(title: str) -> str:
    text = strip_stress(title).lower()
    out = []
    for ch in text:
        if ch in TRANSLIT:
            out.append(TRANSLIT[ch])
        elif ch.isascii() and (ch.isalnum()):
            out.append(ch)
        elif ch in " -–—/,.":
            out.append("-")
    slug = re.sub(r"-+", "-", "".join(out)).strip("-")
    return slug[:60].rstrip("-") or "molitva"


# ── Parsers ──────────────────────────────────────────────────────────────────

def clean_title(heading_html: str) -> str:
    # Drop reference spans like <span class="thin">(Лк.18:13)</span> noise level:
    # keep the parenthetical text — it reads fine in a list.
    title = strip_stress(inline_text(heading_html))
    title = title.lstrip("^ ").rstrip(":").strip()
    # Footnote digit glued to the last word («…Кронштадтского1») — but keep
    # legitimate numbers after a space («Псалом 50»).
    title = re.sub(r"(?<=[а-яё])\d+$", "", title)
    return TITLE_FIXUPS.get(title, title)


# Section titles that are commentary, not prayers.
JUNK_TITLE_RE = re.compile(
    r"^(Как читать|Как правильно|Толкование|Литература|См\.|Аудио|Случайный|Вопросы и ответы)")

# A ЦС-paragraph that opens a commentary block — it and everything after it is dropped.
COMMENTARY_MARKER_RE = re.compile(r"^(Пояснение|Толкование|Примечани[ея]|Комментарий|История)\s*:")

# Standalone junk paragraphs (video/audio embed captions).
JUNK_PARAGRAPH_RE = re.compile(r"^(Видеоноты|Аудио|Слушать|Скачать)\b")


def parse_parallel(html: str, source_url: str) -> list[dict]:
    """Parse a two-column «с параллельным переводом» table page."""
    m = re.search(r"<table[^>]*>(.*?)</table>", html, re.S)
    if not m:
        print("  WARNING: no table found")
        return []
    body = m.group(1)
    prayers: list[dict] = []
    # Content before the first <h3> is the opening (Начало) — keep it.
    current: dict | None = {"title": "Начало", "cs": [], "ru": []}

    for row_m in re.finditer(r"<tr[^>]*>(.*?)</tr>", body, re.S):
        row = row_m.group(1)
        h3 = re.search(r"<h3[^>]*>(.*?)</h3>", row, re.S)
        if h3:
            if current and current["cs"]:
                prayers.append(current)
            current = {"title": clean_title(h3.group(1)), "cs": [], "ru": []}
            continue
        if current is None:
            continue
        cells = re.findall(r"<td[^>]*>(.*?)(?=<td\b|$)", row, re.S)
        # normalize: split on </td> instead (markup is ragged)
        cells = re.split(r"</td>", row)
        cells = [re.sub(r"^.*?<td[^>]*>", "", c, flags=re.S) for c in cells if "<td" in c]
        if len(cells) >= 2:
            for text, rubric in cell_paragraphs(cells[0]):
                current["cs"].append(f"*{text}*" if rubric else text)
            for text, rubric in cell_paragraphs(cells[1]):
                current["ru"].append(f"*{text}*" if rubric else text)
        elif len(cells) == 1:
            # Full-width row: rubric (both languages) or ЦС-only refrain.
            for text, rubric in cell_paragraphs(cells[0]):
                if rubric:
                    current["cs"].append(f"*{text}*")
                    current["ru"].append(f"*{strip_stress(text)}*")
                else:
                    current["cs"].append(text)
                    current["ru"].append(strip_stress(text))
    if current and current["cs"]:
        prayers.append(current)

    reattach_intro_rubrics(prayers)

    out = []
    for p in prayers:
        out.append({
            "title": p["title"],
            "text_cs": "\n\n".join(p["cs"]),
            "text_ru": "\n\n".join(p["ru"]) if p["ru"] else None,
            "source_url": source_url,
        })
    return out


def parse_plain(html: str, source_url: str, heading: str = "h2",
                merge_title: str | None = None) -> list[dict]:
    """Parse an article page: one prayer per <h2>/<h3> section.

    ЦС text lives in <p class="paint">, <p class="gprayer"> or bare <p>;
    <p class="translate"> blocks are Russian translations (kept when they
    start with «Перевод:» or the page is stanza-translated) — joined per
    section into text_ru. Audio-player/junk paragraphs flatten to empty
    strings and are dropped.

    merge_title: if set, all sections are merged into a single prayer with
    this title, section headings becoming *rubric* paragraphs (canons).
    """
    art = re.search(r"<article[^>]*>(.*?)</article>", html, re.S)
    body = art.group(1) if art else html
    # Drop audio-player blocks and scripts outright.
    body = re.sub(r"<div class=\"[^\"]*player[^\"]*\".*?</div>", " ", body, flags=re.S)
    body = re.sub(r"<script.*?</script>", " ", body, flags=re.S)

    sections = re.split(r"<%s[^>]*>" % heading, body)
    parsed: list[dict] = []
    for sec in sections[1:]:
        title_html, _, rest = sec.partition("</%s>" % heading)
        # Content ends at the next lower-level heading (h2 when splitting on h3).
        if heading == "h3":
            rest = re.split(r"<h2[^>]*>", rest)[0]
        title = clean_title(title_html)
        if not title or JUNK_TITLE_RE.match(title):
            continue
        cs_paras: list[str] = []
        ru_paras: list[str] = []
        commentary_started = False
        for pm in re.finditer(r"<p(\s[^>]*)?>(.*?)(?:</p>|(?=<p\b)|(?=<h\d)|$)", rest, re.S):
            attrs = pm.group(1) or ""
            text = inline_text(pm.group(2))
            if not text:
                continue
            if 'class="translate"' in attrs:
                text = re.sub(r"^Перево́?д:\s*", "", text)
                if not commentary_started:
                    ru_paras.append(text)
                continue
            if COMMENTARY_MARKER_RE.match(text):
                commentary_started = True
            if not commentary_started and not JUNK_PARAGRAPH_RE.match(text):
                cs_paras.append(text)
        # «См. текст…» заглушки без собственно молитвы
        if len(cs_paras) == 1 and cs_paras[0].startswith("См.") and len(cs_paras[0]) < 120:
            continue
        if cs_paras:
            parsed.append({"title": title, "cs": cs_paras, "ru": ru_paras})

    reattach_intro_rubrics(parsed)

    if merge_title is not None:
        cs: list[str] = []
        ru: list[str] = []
        for sec in parsed:
            cs.append(f"*{sec['title']}*")
            cs.extend(sec["cs"])
            if sec["ru"]:
                ru.append(f"*{sec['title']}*")
                ru.extend(sec["ru"])
        if not cs:
            return []
        return [{
            "title": merge_title,
            "text_cs": "\n\n".join(cs),
            "text_ru": "\n\n".join(ru) if ru else None,
            "source_url": source_url,
        }]

    return [{
        "title": sec["title"],
        "text_cs": "\n\n".join(sec["cs"]),
        "text_ru": "\n\n".join(sec["ru"]) if sec["ru"] else None,
        "source_url": source_url,
    } for sec in parsed]


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default=DEFAULT_SOURCES)
    ap.add_argument("--output", default=DEFAULT_OUTPUT)
    args = ap.parse_args()

    with open(args.sources, encoding="utf-8") as f:
        config = json.load(f)

    result = {"categories": [], "prayers": []}
    for cat in config["categories"]:
        entry = {k: cat.get(k) for k in
                 ("slug", "title", "subtitle", "icon", "sort_order", "parent")}
        result["categories"].append(entry)
        seen_slugs: dict[str, int] = {}
        sort_order = 0
        for page in cat["pages"]:
            url = page["url"]
            print(f"[{cat['slug']}] {url}")
            html = fetch_page(url)
            if html is None:
                print("  SKIPPED (fetch failed)")
                continue
            if page["kind"] == "parallel":
                prayers = parse_parallel(html, url)
            else:
                prayers = parse_plain(html, url,
                                      heading=page.get("heading", "h2"),
                                      merge_title=page.get("merge_title"))
            print(f"  {len(prayers)} prayers")
            for p in prayers:
                base = f"{cat['slug']}.{slugify(p['title'])}"
                n = seen_slugs.get(base, 0) + 1
                seen_slugs[base] = n
                slug = base if n == 1 else f"{base}-{n}"
                sort_order += 1
                result["prayers"].append({
                    "category_slug": cat["slug"],
                    "slug": slug,
                    "title": p["title"],
                    "sort_order": sort_order,
                    "text_cs": p["text_cs"],
                    "text_ru": p["text_ru"],
                    "source_url": p["source_url"],
                })
            time.sleep(1)

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)

    total = len(result["prayers"])
    with_ru = sum(1 for p in result["prayers"] if p["text_ru"])
    stressed = sum(1 for p in result["prayers"] if STRESS in p["text_cs"])
    print(f"\nSaved {total} prayers ({with_ru} with translation, "
          f"{stressed} with stress marks) → {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
