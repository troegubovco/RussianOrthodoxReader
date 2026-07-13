#!/usr/bin/env python3
"""Step 09 — Match subjects to azbyka.ru pages and scrape lives + prayers.

azbyka.ru/days has two page kinds we use (verified structure, 2026-07):
  /days/sv-{slug}     saints  — житие in div.block.saint-description,
                                prayers in div.inner.taks_content blocks
  /days/ikona-{slug}  icons   — история in div.block.ikon-description,
                                celebration dates in div.brif.celebration

Workflow (semi-automatic, human-in-the-loop):
  1. .venv/bin/python 09_scrape_azbyka.py --probe
         one-off self-test on two known pages (2 requests)
  2. .venv/bin/python 09_scrape_azbyka.py --match
         guess slugs for every classifier class, verify by page title,
         write work/azbyka_match.csv   (~2 requests/class, resumable)
  3. Review azbyka_match.csv: rows with status 'check'/'notfound' — paste the
     correct URL into the url column and set status to 'manual' (find pages
     via site search: https://azbyka.ru/days/search?keywords=<name>)
  4. .venv/bin/python 09_scrape_azbyka.py --scrape
         fetch content for all rows with status ok/manual,
         write work/azbyka_content.json (resumable)
"""
from __future__ import annotations

import argparse
import csv
import difflib
import gzip
import json
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

from bs4 import BeautifulSoup

from common import (AZBYKA_CONTENT_JSON, AZBYKA_MATCH_CSV, LABELS_JSON,
                    base_name, load_labels, paren_variants, translit_slug)

BASE = "https://azbyka.ru/days/"
UA = "RussianOrthodoxReader/1.0 (icon metadata builder; personal app)"
MATCH_FIELDS = ["icon_id", "category", "pravicon_name", "url", "status",
                "matched_title", "note"]


def fetch(url: str, retries: int = 2) -> tuple[str | None, str]:
    """Returns (html, final_url); html=None on 404 or persistent failure."""
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": UA,
                "Accept": "text/html",
                "Accept-Encoding": "gzip",
            })
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                return raw.decode("utf-8", errors="replace"), resp.geturl()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None, url
            if attempt < retries:
                time.sleep(2.0 * (attempt + 1))
        except Exception:
            if attempt < retries:
                time.sleep(2.0 * (attempt + 1))
    return None, url


# --- Parsing -------------------------------------------------------------------

def _block_text(soup: BeautifulSoup, selector: str) -> str | None:
    block = soup.select_one(selector)
    if not block:
        return None
    for bad in block.select("script, style, .taks_audio, sup"):
        bad.decompose()
    text = block.get_text("\n", strip=True)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text if len(text) > 40 else None


def parse_prayers(soup: BeautifulSoup) -> list[dict]:
    prayers = []
    for pos, block in enumerate(soup.select("div.inner.taks_content")):
        h3 = block.find("h3")
        if not h3:
            continue
        glas_el = h3.find("span", class_="glas")
        glas = glas_el.get_text(strip=True) if glas_el else ""
        first_span = h3.find("span")
        kind = (first_span.get_text(strip=True) if first_span
                else h3.get_text(" ", strip=True).split(",")[0])
        for audio in block.select(".taks_audio"):
            audio.decompose()
        body_parts = [p.get_text(" ", strip=True)
                      for p in block.find_all("p")
                      if not p.find_parent("h3") and p.get_text(strip=True)]
        body = "\n\n".join(body_parts).strip()
        if kind and body:
            prayers.append({"kind": kind, "glas": glas, "body": body, "position": pos})
    return prayers


def parse_page(html: str, url: str) -> dict:
    soup = BeautifulSoup(html, "html.parser")
    out: dict = {"url": url, "prayers": parse_prayers(soup)}

    life = _block_text(soup, "div.block.saint-description div.brif")
    history = _block_text(soup, "div.block.ikon-description div.brif")
    if life:
        out["life"] = life
    if history:
        out["history"] = history

    feasts = [a.get_text(strip=True)
              for a in soup.select("div.brif.celebration a, div.block.remembrance-day a")
              if a.get_text(strip=True)]
    if feasts:
        out["feast_days"] = feasts

    meta = soup.find("meta", attrs={"name": "description"})
    if meta and meta.get("content"):
        out["meta_description"] = meta["content"].strip()

    title = soup.find("title")
    if title:
        out["title"] = title.get_text(strip=True)
    return out


# --- Matching ------------------------------------------------------------------

def candidate_slugs(name: str, category: str) -> list[str]:
    variants = paren_variants(base_name(name))
    slugs = []
    for v in variants:
        s = translit_slug(v)
        if not s:
            continue
        if category == "saints":
            slugs.append(f"sv-{s}")
        elif category == "theotokos":
            slugs.append(f"ikona-{s}")
        else:  # christ, angels — page kind varies
            slugs += [f"sv-{s}", f"ikona-{s}", f"prazdnik-{s}"]
    seen, unique = set(), []
    for s in slugs:
        if s not in seen:
            seen.add(s)
            unique.append(s)
    return unique


def title_score(title: str, name: str) -> float:
    title_low = title.lower().split(":")[0]
    best = 0.0
    for v in paren_variants(base_name(name)):
        v_low = v.lower()
        if v_low and v_low in title_low:
            return 1.0
        best = max(best, difflib.SequenceMatcher(None, v_low, title_low).ratio())
    return best


def read_match_csv() -> dict[int, dict]:
    rows = {}
    if AZBYKA_MATCH_CSV.exists():
        with open(AZBYKA_MATCH_CSV, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                rows[int(r["icon_id"])] = r
    return rows


def write_match_csv(rows: dict[int, dict]):
    order = {"notfound": 0, "check": 1, "": 2, "ok": 3, "manual": 3}
    with open(AZBYKA_MATCH_CSV, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=MATCH_FIELDS)
        w.writeheader()
        for r in sorted(rows.values(),
                        key=lambda r: (order.get(r.get("status", ""), 2),
                                       r.get("category", ""), int(r["icon_id"]))):
            w.writerow({k: r.get(k, "") for k in MATCH_FIELDS})


def cmd_match(delay: float):
    classes = load_labels(LABELS_JSON)
    existing = read_match_csv()
    todo = [c for c in classes
            if existing.get(c["icon_id"], {}).get("status") not in ("ok", "manual")]
    print(f"{len(classes)} classes, {len(todo)} to match "
          f"(~{len(todo) * (delay + 0.6) * 1.5 / 60:.0f} min)")

    for i, c in enumerate(todo):
        icon_id, name, category = c["icon_id"], c["name"], c["category"]
        row = {"icon_id": str(icon_id), "category": category, "pravicon_name": name,
               "url": "", "status": "notfound", "matched_title": "", "note": ""}
        for slug in candidate_slugs(name, category)[:4]:
            html, final_url = fetch(BASE + slug)
            time.sleep(delay)
            if html is None:
                continue
            title_el = re.search(r"<title>(.*?)</title>", html, re.DOTALL)
            title = title_el.group(1).strip() if title_el else ""
            score = title_score(title, name)
            if score >= 0.55:
                row.update(url=final_url, status="ok", matched_title=title)
                break
            if row["status"] == "notfound":
                row.update(url=final_url, status="check", matched_title=title,
                           note=f"score={score:.2f}")
        existing[icon_id] = row
        print(f"[{i + 1}/{len(todo)}] {name[:50]:50s} -> {row['status']}")
        if (i + 1) % 20 == 0:
            write_match_csv(existing)

    write_match_csv(existing)
    by_status = {}
    for r in existing.values():
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1
    print(f"Done: {by_status} -> {AZBYKA_MATCH_CSV}")
    print("Review rows with status check/notfound, set status=manual with a "
          "corrected url, then run --scrape.")


def cmd_scrape(delay: float, refetch: bool):
    matches = read_match_csv()
    content: dict[str, dict] = {}
    if AZBYKA_CONTENT_JSON.exists():
        with open(AZBYKA_CONTENT_JSON, encoding="utf-8") as f:
            content = json.load(f)

    todo = [r for r in matches.values()
            if r.get("status") in ("ok", "manual") and r.get("url")
            and (refetch or str(r["icon_id"]) not in content)]
    print(f"{len(todo)} pages to scrape")

    def save():
        AZBYKA_CONTENT_JSON.parent.mkdir(parents=True, exist_ok=True)
        with open(AZBYKA_CONTENT_JSON, "w", encoding="utf-8") as f:
            json.dump(content, f, ensure_ascii=False, indent=1)

    for i, r in enumerate(todo):
        html, final_url = fetch(r["url"])
        time.sleep(delay)
        if html is None:
            print(f"[{i + 1}/{len(todo)}] FAILED {r['url']}")
            continue
        parsed = parse_page(html, final_url)
        content[str(r["icon_id"])] = parsed
        got = [k for k in ("life", "history") if k in parsed]
        print(f"[{i + 1}/{len(todo)}] {r['pravicon_name'][:44]:44s} "
              f"{'+'.join(got) or 'NO TEXT'} prayers={len(parsed['prayers'])}")
        if (i + 1) % 20 == 0:
            save()
    save()

    n_life = sum(1 for v in content.values() if v.get("life"))
    n_hist = sum(1 for v in content.values() if v.get("history"))
    n_pray = sum(1 for v in content.values() if v.get("prayers"))
    print(f"Done: {len(content)} pages, life={n_life}, history={n_hist}, "
          f"with prayers={n_pray} -> {AZBYKA_CONTENT_JSON}")


def cmd_probe():
    ok = True
    for url, expect in [
        ("https://azbyka.ru/days/sv-spiridon-trimifuntskij", "life"),
        ("https://azbyka.ru/days/ikona-kazanskaja", "history"),
    ]:
        html, final_url = fetch(url)
        if html is None:
            print(f"PROBE FAILED: cannot fetch {url}")
            ok = False
            continue
        parsed = parse_page(html, final_url)
        text = parsed.get(expect, "")
        print(f"--- {url}")
        print(f"    title: {parsed.get('title', '')[:70]}")
        print(f"    {expect}: {len(text)} chars | {text[:90]!r}")
        print(f"    feasts: {parsed.get('feast_days')}")
        print(f"    prayers: {[(p['kind'], p['glas'], len(p['body'])) for p in parsed['prayers']]}")
        if not text or not parsed["prayers"]:
            print("    PROBE FAILED: missing expected content — azbyka markup "
                  "may have changed; update selectors in parse_page()")
            ok = False
        time.sleep(1.0)
    raise SystemExit(0 if ok else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--match", action="store_true")
    parser.add_argument("--scrape", action="store_true")
    parser.add_argument("--refetch", action="store_true")
    parser.add_argument("--delay", type=float, default=1.5)
    args = parser.parse_args()

    if args.probe:
        cmd_probe()
    elif args.match:
        cmd_match(args.delay)
    elif args.scrape:
        cmd_scrape(args.delay, args.refetch)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
