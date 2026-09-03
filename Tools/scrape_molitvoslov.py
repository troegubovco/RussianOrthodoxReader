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
import socket
import sys
import time
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SOURCES = os.path.join(SCRIPT_DIR, "data", "molitvoslov_sources.json")
DEFAULT_OUTPUT = os.path.join(SCRIPT_DIR, "data", "molitvoslov_raw.json")

STRESS = "́"  # combining acute accent

# A footnote-marker digit glued straight onto a word (with an optional stress
# mark in between, e.g. «просфора́1»); a number after a space («Псалом 50»)
# never matches.
FOOTNOTE_DIGIT_RE = re.compile(r"(?<=[а-яёА-ЯЁ])\d+|(?<=[а-яёА-ЯЁ]́)\d+")

# azbyka.ru's direct DNS answer gets a 403 from this network; pin the host to
# its known-good IP while keeping the Host header / TLS SNI as azbyka.ru
# (same trick as `curl --resolve`). Scoped to this one hostname only.
AZBYKA_HOST = "azbyka.ru"
AZBYKA_IP = "87.228.124.164"
_orig_getaddrinfo = socket.getaddrinfo


def _pinned_getaddrinfo(host, *args, **kwargs):
    if host == AZBYKA_HOST:
        host = AZBYKA_IP
    return _orig_getaddrinfo(host, *args, **kwargs)


socket.getaddrinfo = _pinned_getaddrinfo


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
    """Remove footnote markers glued onto words: <sup>…</sup> (usually a
    digit), and azbyka's bare <a href="#_ftnaN">*</a> / <a href="#_ftnN">…</a>
    reference links (no <sup> wrapper, sometimes an asterisk instead of a
    digit) that show up in both body paragraphs and headings."""
    html = re.sub(r"<sup[^>]*>.*?</sup>", "", html, flags=re.S)
    html = re.sub(r'<a[^>]*href="#_ftna?\d+"[^>]*>.*?</a>', "", html, flags=re.S)
    return html


def inline_text(html: str) -> str:
    """Flatten inline markup to plain text (keeps link/emphasis inner text)."""
    html = strip_footnotes(html)
    html = re.sub(r"<br\s*/?>", "\n", html)
    html = re.sub(r"<[^>]+>", "", html)
    html = decode_entities(html)
    # Invisible characters azbyka's markup occasionally leaves behind: a
    # zero-width space (&#8203;), a stray BOM/ZWNBSP (&#65279;, seen at
    # the very start of some articles), and soft hyphens (U+00AD — 1,715 of
    # them inside words on the Ангел-хранитель akathist alone).
    html = html.replace("​", "").replace("﻿", "").replace("\xad", "")
    # Footnote digits glued to words outside <sup> («взе́мляй1», «просфора́1» —
    # the lookbehind also covers a stress mark right before the digit);
    # numbers after a space («Псалом 50») are untouched.
    html = FOOTNOTE_DIGIT_RE.sub("", html)
    html = fix_latin_cyrillic_confusables(html)
    return re.sub(r"[ \t]+", " ", html).strip()


# Latin letters azbyka's markup occasionally typoes in place of their
# visually-identical Cyrillic counterpart (seen so far: a stray Latin p in
# тропарь texts — «Тво́pче», «pук», «Стpастоте́pпче» — and a Latin drop-cap O
# opening «О́тче наш»). Kept to genuinely confusable glyph pairs only.
_LATIN_CYRILLIC_CONFUSABLES = str.maketrans({
    "A": "А", "a": "а", "B": "В", "E": "Е", "e": "е", "K": "К", "k": "к",
    "M": "М", "m": "м", "H": "Н", "O": "О", "o": "о", "P": "Р", "p": "р",
    "C": "С", "c": "с", "T": "Т", "t": "т", "X": "Х", "x": "х", "Y": "У", "y": "у",
})


def fix_latin_cyrillic_confusables(text: str) -> str:
    """Only touches a run of letters (stress marks don't break the run) that
    mixes genuine Cyrillic with a confusable Latin letter; a real Latin word
    (no Cyrillic anywhere in the same run) is left alone."""
    def repl(m: re.Match) -> str:
        word = m.group(0)
        if re.search(r"[а-яёА-ЯЁ]", word) and re.search(r"[a-zA-Z]", word):
            word = word.translate(_LATIN_CYRILLIC_CONFUSABLES)
        return word
    return re.sub(r"(?:[а-яёА-ЯЁa-zA-Z]|" + STRESS + r")+", repl, text)


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
    # A <br> inside the heading (inline_text turns it into \n) shouldn't
    # survive into a one-line list title.
    title = re.sub(r"\s+", " ", title)
    # Headings show up as «Кондак 1», «Кондак 1:» and «Кондак 1.» across
    # akathist pages — normalize all three to the same bare form so they
    # merge into one rubric spelling and one slug.
    title = title.lstrip("^ ").rstrip(":.").strip()
    # Footnote digit glued to the last word («…Кронштадтского1») — but keep
    # legitimate numbers after a space («Псалом 50»).
    title = re.sub(r"(?:(?<=[а-яё])|(?<=[а-яё]́))\d+$", "", title)
    # Footnote digit glued straight onto a «глас N» tone number («глас 21» —
    # there is no tone above 8, so the trailing digit is always a footnote).
    title = re.sub(r"(?<=глас \d)\d+$", "", title)
    return TITLE_FIXUPS.get(title, title)


# Section titles that are commentary, not prayers.
JUNK_TITLE_RE = re.compile(
    r"^(Как читать|Как правильно|Толкование|Литература|См\.|Аудио|Случайный|"
    r"Вопросы и ответы|Краткое житие|Житие|Личное прошение|Рекомендуем молитвы|"
    r"Близкие понятия|Об акафисте)")

# A ЦС-paragraph that opens a commentary block — it and everything after it is dropped.
COMMENTARY_MARKER_RE = re.compile(r"^(Пояснение|Толкование|Примечани[ея]|Комментарий|История)\s*:")

# A one-off explanatory sentence some «Толкования тропарей» pages append right
# after a тропарь/кондак («Тропарь 1-го гласа говорит о том, что…», «В кондаке
# 2-го гласа говорится о том, что…») — commentary, not liturgical text.
TONE_EXPLAIN_RE = re.compile(
    r"^(?:Тропарь|Кондак|В (?:тропаре|кондаке))\b.{0,30}?глас.{0,25}?говор")

# A bare «* * *» divider — azbyka uses it to separate the prayer text from a
# following толкование/comment block. Treated like a commentary marker: it
# and anything after it (within the section) is dropped.
DIVIDER_RE = re.compile(r"^\*(\s*\*)+$")

# Standalone junk paragraphs (video/audio embed captions, «continue reading
# elsewhere» pointers like the Great Canon's trailing «Далее см. Великое
# повечерие.»).
JUNK_PARAGRAPH_RE = re.compile(
    r"^(Видеоноты\b|Аудио\b|Слушать\b|Скачать\b|См\.\s*также\b|Далее см\.|Примечания\b)")

# A paragraph that is only a numbered-variant marker («1.», «2.», or «3.*» when
# the number carries a footnote reference styled as «*» instead of a digit) —
# some azbyka pages put these in their own <p class="center"><strong>N.</strong></p>
# ahead of the variant's actual text. Never real prayer content.
NUMERAL_MARKER_RE = re.compile(r"^\d{1,2}\.?\**$")

# The bottom-of-page footnote LIST (translator credits, word glosses, source
# citations — e.g. akafist-pokrovu-presvyatoj-bogorodicy's «Примечания»)
# opens each entry with a back-link to the in-text marker: `<a href="#_ftnrefN"
# ...>[N]</a> text…`, sometimes several `<br>`-joined entries in one <p>.
# strip_footnotes() doesn't touch it (its href doesn't match `#_ftnaN`), and
# once the [N] <sup>/<a> markup is gone the note reads as ordinary prose —
# seen leaking onto 4 of the 12 akathist pages. The IN-TEXT marker a comment
# footnote points FROM is the mirror shape (`href="#_ftnN"`, mid-sentence,
# never at the very start of a paragraph) and must not be caught by this.
FOOTNOTE_LIST_RE = re.compile(r'^\s*<a\b[^>]*href="#_ftnref\d+"')

# ── akafisty/canons additions (akathist_psalter_design.md §2.2, §8.5) ────────

# A paragraph whose ENTIRE content is one <em>/<i> tag — azbyka's scripture-
# citation comments on akathist pages («<p><em>Сошествие Христа во ад
# (Мф.12:40)</em></p>») and a couple of stray editorial notes («Текст
# утвержден Священным Синодом…», «Одобрен решением Св. Синода…») take this
# exact shape. A genuine italicized liturgical refrain (e.g. the Ангелу
# хранителю canon's «Святый Ангеле Божий…» припев, repeated after every
# tropar) is ALSO fully <em>-wrapped, but always keeps the site's red/maroon
# drop-cap <span> on its first letter — comments never do. That drop-cap is
# the signal used to tell the two apart (verified against all 12 akathist +
# 4 Great Canon pages + the 3 already-shipped canons: 44 dropped, 13 kept,
# zero false positives either way).
EM_WRAPS_ALL_RE = re.compile(r"^<(em|i)(?:\s[^>]*)?>(.*)</\1>$", re.S)
EM_STYLED_DROPCAP_RE = re.compile(r'^\s*<span class="(?:red|maroon)">')


def _is_dropped_em_comment(inner_html: str, classes: set[str]) -> bool:
    if classes & {"paint", "gprayer", "maroon-first"}:
        return False
    m = EM_WRAPS_ALL_RE.match(inner_html.strip())
    if not m:
        return False
    return not EM_STYLED_DROPCAP_RE.match(m.group(2))


# «Сей кондак глаголется трижды» / «Далее повторяем 1-е икос и кондак:» —
# azbyka marks this instruction with class="center" or "text-center", never
# <strong>, so is_rubric() doesn't see it. Two shapes: wholly bracketed
# (sometimes two bracket groups back to back in one <p>: «[A.][B.]» — split
# into separate rubric lines) or, on one page, unbracketed but matching the
# same stock phrasing.
CENTER_RUBRIC_CLASSES = {"center", "text-center"}
CENTER_RUBRIC_KEYWORDS_RE = re.compile(
    r"чита[ея]тся|глаголется|трижды|далее повторяем", re.IGNORECASE)


def _center_rubric_paragraphs(text: str) -> list[str]:
    brackets = [b.strip() for b in re.findall(r"\[([^\[\]]+)\]", text) if b.strip()]
    if brackets:
        return brackets
    if CENTER_RUBRIC_KEYWORDS_RE.search(strip_stress(text)):
        return [text.strip()]
    return []


# Great Canon RU translations (p.translate) are wrapped in [brackets], the
# very first one on each page also carrying a «– Перевод Н.И. Кедрова»
# credit before the closing bracket, and roughly a third of them a trailing
# «(book.chapter:verse)» scripture reference after it. A handful of
# paragraphs have unbalanced brackets in azbyka's own markup (missing «]», or
# a stray extra «)»); the cleanup below does what it can and leaves the rest
# rather than guess. A no-op on any text that doesn't start with «[» — safe
# to run unconditionally on every category's translate paragraphs.
CANON_TRAILING_REF_RE = re.compile(r"\s*\([^()]*\d[^()]*\)\s*$")
CANON_TRANSLATOR_CREDIT_RE = re.compile(r"\s*–\s*Перевод[^\]]*\]")


def clean_canon_translation(text: str) -> str:
    text = text.strip()
    if not text.startswith("["):
        return text
    text = CANON_TRAILING_REF_RE.sub("", text)
    text = CANON_TRANSLATOR_CREDIT_RE.sub("]", text)
    text = text[1:]
    if text.endswith("]"):
        text = text[:-1]
    text = text.strip()
    if text.endswith(")") and text.count("(") < text.count(")"):
        text = text[:-1].rstrip()
    return text


# The final, positive list of ЦС-paragraph classes in _plain_paragraphs
# (§2.2 rule 3): a bare <p> (no class at all) or one of these three. Any
# other named class (icon_fixed, header-subtitle, …) never carries prayer
# text and is dropped rather than risk leaking a decorative/navigation
# paragraph into text_cs.
ALLOWED_CS_CLASSES = {"paint", "gprayer", "maroon-first"}


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


def _class_tokens(attrs: str) -> set[str]:
    """Space-separated class="..." tokens on a tag (never assume a single
    class — azbyka sometimes writes class="translate translate-2")."""
    m = re.search(r'class="([^"]*)"', attrs)
    return set(m.group(1).split()) if m else set()


def _plain_paragraphs(rest: str) -> tuple[list[str], list[str]]:
    """Extract (cs_paras, ru_paras) from a chunk of article HTML using the
    same paragraph rules as parse_plain's per-section loop. Shared so the
    pre-heading intro (include_intro) is parsed identically to a section."""
    cs_paras: list[str] = []
    ru_paras: list[str] = []
    commentary_started = False
    for pm in re.finditer(r"<p(\s[^>]*)?>(.*?)(?:</p>|(?=<p\b)|(?=<h\d)|$)", rest, re.S):
        attrs = pm.group(1) or ""
        if FOOTNOTE_LIST_RE.match(pm.group(2)):
            continue
        text = inline_text(pm.group(2))
        if not text or NUMERAL_MARKER_RE.match(text):
            continue
        classes = _class_tokens(attrs)
        if any(c.startswith("translate-") for c in classes):
            # A second, freer translation — class="translate-2" alone, or
            # (as azbyka often writes it) BOTH "translate" and "translate-2"
            # on the same <p>. Check this before the plain "translate" branch
            # below, or the translate-2 half of that combo would be treated
            # as our primary text_ru. Not our text_ru and NOT ЦС text either,
            # so it must be dropped outright rather than falling through to
            # cs_paras below.
            continue
        if "translate" in classes:
            # «Перевод:» on most pages, «Перевод 1:» on the Пресвятой
            # Богородице akathist (which numbers its kept translation
            # alongside the translate-2/3/4 alternates dropped above).
            text = re.sub(r"^Перево́?д(?:\s*\d+)?:\s*", "", text)
            text = clean_canon_translation(text)
            if not commentary_started and text:
                ru_paras.append(text)
            continue
        if classes & CENTER_RUBRIC_CLASSES:
            rubrics = _center_rubric_paragraphs(text)
            if rubrics:
                if not commentary_started:
                    cs_paras.extend(f"*{r}*" for r in rubrics)
                continue
            # Not a recognized rubric shape (e.g. a bare "* * *" divider) —
            # fall through to the commentary-marker checks below as normal.
        if COMMENTARY_MARKER_RE.match(text) or DIVIDER_RE.match(text) or TONE_EXPLAIN_RE.match(text):
            commentary_started = True
            continue
        if _is_dropped_em_comment(pm.group(2), classes):
            continue
        if classes and not (classes & ALLOWED_CS_CLASSES):
            continue
        if not commentary_started and not JUNK_PARAGRAPH_RE.match(text):
            cs_paras.append(text)
    return cs_paras, ru_paras


def parse_plain(html: str, source_url: str, heading: str = "h2",
                merge_title: str | None = None,
                sections: list[str] | None = None,
                include_intro: bool = False,
                section_selector: str | None = None) -> list[dict]:
    """Parse an article page: one prayer per <h2>/<h3> section.

    ЦС text lives in <p class="paint">, <p class="gprayer"> or bare <p>;
    <p class="translate"> blocks are Russian translations (kept when they
    start with «Перевод:» or the page is stanza-translated) — joined per
    section into text_ru. Audio-player/junk paragraphs flatten to empty
    strings and are dropped.

    merge_title: if set, all (kept) sections are merged into a single prayer
    with this title, section headings becoming *rubric* paragraphs (canons).

    sections: if set, an allowlist of exact (post-clean_title) section titles
    to keep — everything else on the page is dropped before merging/output.
    For long azbyka pages (30+ kB, dozens of sections) that only contribute a
    handful of prayers to the app.

    include_intro: if set (with merge_title), the paragraphs BEFORE the first
    heading are parsed the same way and prepended to the merged text — some
    services (e.g. a лития) print their opening rubric/prayers ahead of the
    first <h3>, which a plain per-heading split would otherwise drop.

    section_selector: if set, crop the article down to the first sibling
    <section class="…"> matching this class (up to the NEXT <section> tag,
    or the end of the article if there isn't one) before doing anything else.
    The Иисусу Сладчайшему akathist prints two full copies of the akathist
    inside <section class="type-male">/"type-female"> — without this, every
    heading and paragraph count above would double.
    """
    art = re.search(r"<article[^>]*>(.*?)</article>", html, re.S)
    body = art.group(1) if art else html
    # Drop audio-player blocks and scripts outright.
    body = re.sub(r"<div class=\"[^\"]*player[^\"]*\".*?</div>", " ", body, flags=re.S)
    body = re.sub(r"<script.*?</script>", " ", body, flags=re.S)

    if section_selector:
        m = re.search(r'<section class="%s"[^>]*>' % re.escape(section_selector), body)
        if m:
            rest = body[m.end():]
            nxt = re.search(r"<section\b", rest)
            body = rest[:nxt.start()] if nxt else rest
        else:
            print(f"  WARNING: section_selector {section_selector!r} not found")

    raw_sections = re.split(r"<%s[^>]*>" % heading, body)
    intro_cs: list[str] = []
    intro_ru: list[str] = []
    if include_intro and raw_sections:
        intro_cs, intro_ru = _plain_paragraphs(raw_sections[0])
    parsed: list[dict] = []
    for sec in raw_sections[1:]:
        title_html, _, rest = sec.partition("</%s>" % heading)
        # Content ends at the next lower-level heading (h2 when splitting on h3).
        if heading == "h3":
            rest = re.split(r"<h2[^>]*>", rest)[0]
        title = clean_title(title_html)
        if not title or JUNK_TITLE_RE.match(title):
            continue
        cs_paras, ru_paras = _plain_paragraphs(rest)
        # «См. текст…» заглушки без собственно молитвы
        if len(cs_paras) == 1 and cs_paras[0].startswith("См.") and len(cs_paras[0]) < 120:
            continue
        if cs_paras:
            parsed.append({"title": title, "cs": cs_paras, "ru": ru_paras})

    reattach_intro_rubrics(parsed)

    if sections is not None:
        wanted = set(sections)
        parsed = [sec for sec in parsed if sec["title"] in wanted]

    if merge_title is not None:
        cs: list[str] = list(intro_cs)
        ru: list[str] = list(intro_ru)
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


# ── Псалтирь по кафизмам — one page, its own structure (§1.3, §7 A2) ─────────

# Psalm range shown in each kathisma's subtitle — matches azbyka's own TOC
# labels (e.g. «Кафисма 20-я (псалмы 143–151)») and the printed Psalter's
# traditional kathisma boundaries. Verified against the scraped page: every
# boundary and every 3-Слава count below matches exactly.
KATHISMA_PSALM_RANGE = {
    1: "1–8", 2: "9–16", 3: "17–23", 4: "24–31", 5: "32–36", 6: "37–45",
    7: "46–54", 8: "55–63", 9: "64–69", 10: "70–76", 11: "77–84", 12: "85–90",
    13: "91–100", 14: "101–104", 15: "105–108", 16: "109–117", 17: "118",
    18: "119–133", 19: "134–142", 20: "143–151",
}

# The kathisma-dividing «Слава» marker is an ISOLATED paragraph whose entire
# content is the span — nothing else in the <p>. A «Слава: <troparion text>»
# paragraph inside the trailing tropari block (the ordinary «Слава, и ныне:»
# doxology pairing) has the same span but with text after it, and must NOT
# be treated as a divider — this regex only matches the bare, divider shape
# (confirmed exactly 60 on the page, 3 per kathisma, per §1.3).
SLAVA_DIVIDER_RE = re.compile(r'^<span class="letter">Слава:</span>$')

# Kathisma 17 (Psalm 118) carries one more isolated <span class="letter">
# label besides «Слава:» — «[Среда́:]», a leftover weekday marker from the
# funeral-service tradition of reading Psalm 118 in day groups. Same bare
# shape as the Слава divider; render it as a rubric too instead of leaving
# literal brackets glued into the verse flow.
ISOLATED_LETTER_LABEL_RE = re.compile(r'^<span class="letter">(.*?)</span>$')


def _psaltir_walk(section_html: str, kathisma: int | None) -> list[str]:
    """Walk a psaltir section's <h3>/<p> tags in document order. Turns each
    «Псалом N» heading and each isolated «Слава» divider into a *rubric*
    line, and the «По N-й кафисме, Трисвятое…» tail instruction — already
    marked up as <strong><em>…</em></strong>, so is_rubric() sees it — into
    one too. kathisma is None for the intro/closing sections (no psalm-151
    special case there)."""
    out: list[str] = []
    for m in re.finditer(r"<h3[^>]*>(.*?)</h3>|<p(\s[^>]*)?>(.*?)</p>", section_html, re.S):
        if m.group(1) is not None:
            title = clean_title(m.group(1))
            if kathisma == 20 and title == "Псалом 151":
                # §1.3: printed after the 3rd Слава, marked as outside the
                # numbered 150 — same rubric shape as the rest («*Псалом
                # 151…*») so the psalm-gap check still recognizes it.
                title = "Псалом 151 — вне числа 150 псалмов"
            out.append(f"*{title}*")
            continue
        inner = m.group(3)
        text = inline_text(inner)
        if not text or NUMERAL_MARKER_RE.match(text):
            continue
        if SLAVA_DIVIDER_RE.match(inner.strip()):
            out.append("*Слава*")
            continue
        m_label = ISOLATED_LETTER_LABEL_RE.match(inner.strip())
        if m_label:
            label = inline_text(m_label.group(1)).strip("[] ")
            if label:
                out.append(f"*{label}*")
            continue
        if is_rubric(inner):
            out.append(f"*{text}*")
            continue
        if COMMENTARY_MARKER_RE.match(text) or DIVIDER_RE.match(text) or TONE_EXPLAIN_RE.match(text):
            continue
        if JUNK_PARAGRAPH_RE.match(text):
            continue
        out.append(text)
    return out


def parse_psaltir(html: str, source_url: str) -> list[dict]:
    """Parse azbyka's single-page «Псалтирь по кафизмам» into 22 prayers:
    the opening prayers, 20 kathismas (each ending in its own tropari/
    молитва tail block, printed inline right after the 3rd Слава — §1.2),
    and the closing prayers. ЦС only — the page has no Russian translation
    column, so text_ru is always None here."""
    art = re.search(r"<article[^>]*>(.*?)</article>", html, re.S)
    body = art.group(1) if art else html
    body = re.sub(r"<script.*?</script>", " ", body, flags=re.S)

    raw_sections = re.split(r"<h2[^>]*>", body)
    # index 0 = pre-first-h2 preamble (TOC + "См.:" cross-link — not one of
    # the 22 target sections, dropped same as parse_plain drops it);
    # 1 = opening prayers; 2 = empty "Давида пророка и царя песнь" caption;
    # 3..22 = Кафисма 1..20; 23 = closing prayers; 24 = "Рекомендуем молитвы".
    if len(raw_sections) != 25:
        print(f"  WARNING: expected 25 <h2>-delimited pieces on the psaltir "
              f"page (24 headings), found {len(raw_sections)} — page layout "
              f"may have changed")

    def section_rest(idx: int) -> str:
        _, _, rest = raw_sections[idx].partition("</h2>")
        return rest

    sections: list[dict] = []

    intro_cs = _psaltir_walk(section_rest(1), None)
    if intro_cs:
        sections.append({"title": "Молитвы перед чтением", "cs": intro_cs})

    for k in range(1, 21):
        cs = _psaltir_walk(section_rest(2 + k), k)
        if cs:
            sections.append({"title": f"Кафизма {k}", "cs": cs})

    closing_cs = _psaltir_walk(section_rest(23), None)
    if closing_cs:
        sections.append({"title": "Молитвы по прочтении", "cs": closing_cs})

    return [{
        "title": sec["title"],
        "text_cs": "\n\n".join(sec["cs"]),
        "text_ru": None,
        "source_url": source_url,
    } for sec in sections]


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default=DEFAULT_SOURCES)
    ap.add_argument("--output", default=DEFAULT_OUTPUT)
    ap.add_argument("--only", default=None,
                     help="Comma-separated category slugs to (re)scrape. Merges into "
                          "the existing --output file: only the listed categories' "
                          "prayers are replaced (or added, if new); every other "
                          "category's previously scraped prayers is carried over "
                          "unchanged. Without --only the whole config is re-scraped "
                          "and --output is overwritten as before.")
    args = ap.parse_args()

    with open(args.sources, encoding="utf-8") as f:
        config = json.load(f)

    only = set(args.only.split(",")) if args.only else None

    # In --only mode, start from whatever is already on disk so untouched
    # categories' prayers survive verbatim.
    existing_prayers_by_cat: dict[str, list] = {}
    if only is not None and os.path.exists(args.output):
        with open(args.output, encoding="utf-8") as f:
            prev = json.load(f)
        for p in prev.get("prayers", []):
            existing_prayers_by_cat.setdefault(p["category_slug"], []).append(p)

    result = {"categories": [], "prayers": []}
    # config["categories"] already lists parents before children — always
    # rebuild the categories list from it (in that order) so a freshly-added
    # category lands in the right place relative to its parent, whether or
    # not it's in --only.
    for cat in config["categories"]:
        entry = {k: cat.get(k) for k in
                 ("slug", "title", "subtitle", "icon", "sort_order", "parent")}
        result["categories"].append(entry)

        if only is not None and cat["slug"] not in only:
            result["prayers"].extend(existing_prayers_by_cat.get(cat["slug"], []))
            continue

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
            elif page["kind"] == "psaltir":
                prayers = parse_psaltir(html, url)
            else:
                prayers = parse_plain(html, url,
                                      heading=page.get("heading", "h2"),
                                      merge_title=page.get("merge_title"),
                                      sections=page.get("sections"),
                                      include_intro=page.get("include_intro", False),
                                      section_selector=page.get("section_selector"))
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
