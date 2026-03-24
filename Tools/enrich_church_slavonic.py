#!/usr/bin/env python3
"""
Enrich Church Slavonic dictionary entries with expanded definitions using a local
YandexGPT MLX model.

Run with the MLX virtualenv:
    /Users/andreyt/Developer/mlx_env/bin/python Tools/enrich_church_slavonic.py

Flags:
    --limit N     Process only the first N entries (use 10 for a test run)
    --start N     Skip the first N entries (for resuming an interrupted run)
    --apply       Read the enriched JSON and write definitions back to SQLite

Workflow:
    1. Test:   python enrich_church_slavonic.py --limit 10
    2. Review: open Tools/data/church_slavonic_enriched.json, check quality
    3. Full:   python enrich_church_slavonic.py          (resumable)
    4. Merge:  python enrich_church_slavonic.py --apply
"""

import argparse
import json
import os
import sqlite3
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)

SQLITE_PATH = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "Bible", "rus_dictionary.sqlite")
MODEL_PATH = "/Users/andreyt/Developer/Models/YandexGPT-q8"
OUTPUT_JSON = os.path.join(SCRIPT_DIR, "data", "church_slavonic_enriched.json")
CHECKPOINT_EVERY = 50
SOURCE = "Церковнославянский словарь"


def load_entries(start: int, limit: int | None) -> list[dict]:
    conn = sqlite3.connect(SQLITE_PATH)
    cur = conn.cursor()
    cur.execute(
        "SELECT rowid, word, definition FROM entries WHERE source = ? ORDER BY rowid",
        (SOURCE,)
    )
    rows = cur.fetchall()
    conn.close()

    rows = rows[start:]
    if limit is not None:
        rows = rows[:limit]

    return [{"rowid": r[0], "word": r[1], "original": r[2]} for r in rows]


def build_prompt(word: str, definition: str) -> str:
    return (
        "Ты — эксперт по церковнославянскому языку и православному богословию. "
        "Твоя задача — обогатить краткое определение церковнославянского слова, чтобы помочь читателю понять его значение "
        "в контексте богослужебного текста и отличие от современного русского аналога.\n"
        "Формат ответа:\n"
        "1. Начинай с оригинального перевода (не меняй его).\n"
        "2. Добавь 1–2 предложения, которые раскроют:\n"
        "* литургический контекст употребления слова (если есть);\n"
        "* этимологию слова;\n"
        "* разницу в значении между церковнославянским словом и его современным русским аналогом;\n"
        "* примеры реального употребления в богослужебных текстах (при условии абсолютной уверенности в их точности).\n"
        "Важные ограничения:\n"
        "* не выдумывай литургические связи и цитаты — приводи только реальные примеры;\n"
        "* если нет значимого современного аналога или литургического контекста, не придумывай их, "
        "но постарайся найти другой способ раскрыть значение;\n"
        "* избегай шаблонных фраз вроде «В литургическом контексте может использоваться…»;\n"
        "* ответ должен быть кратким — не более 2–3 предложений после оригинального перевода.\n"
        "Старайся сфокусироваться на том, как значение слова могло отличаться в церковнославянском языке "
        "по сравнению с современным русским языком, и на том, как это слово использовалось в богослужебном контексте. "
        "Если добавить нечего — верни только оригинальный перевод без изменений.\n\n"
        f"Слово: {word}\n"
        f"Краткий перевод: {definition}\n"
        "Расширенное определение:"
    )


def load_existing_results() -> list[dict]:
    if os.path.exists(OUTPUT_JSON):
        with open(OUTPUT_JSON, encoding="utf-8") as f:
            return json.load(f)
    return []


def save_results(results: list[dict]):
    os.makedirs(os.path.dirname(OUTPUT_JSON), exist_ok=True)
    with open(OUTPUT_JSON, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)


def apply_to_sqlite(results: list[dict]):
    """Write enriched definitions back to the SQLite database."""
    conn = sqlite3.connect(SQLITE_PATH)
    cur = conn.cursor()
    updated = 0
    skipped = 0
    for entry in results:
        if entry.get("status") != "ok" or not entry.get("enriched"):
            skipped += 1
            continue
        cur.execute(
            "UPDATE entries SET definition = ? WHERE rowid = ? AND source = ?",
            (entry["enriched"], entry["rowid"], SOURCE)
        )
        updated += 1
    conn.commit()
    conn.close()
    print(f"Applied: {updated} updated, {skipped} skipped (no result or status != ok)")


def main():
    parser = argparse.ArgumentParser(description="Enrich Church Slavonic definitions with local YandexGPT")
    parser.add_argument("--limit", type=int, default=None, help="Process only N entries")
    parser.add_argument("--start", type=int, default=0, help="Skip first N entries")
    parser.add_argument("--apply", action="store_true", help="Apply enriched JSON to SQLite")
    args = parser.parse_args()

    if args.apply:
        print(f"Reading enriched results from: {OUTPUT_JSON}")
        results = load_existing_results()
        if not results:
            print("No results found. Run without --apply first.")
            sys.exit(1)
        apply_to_sqlite(results)
        return

    # Load mlx_lm lazily so --apply works without the MLX env
    try:
        from mlx_lm import load, generate
    except ImportError:
        print("mlx-lm not found. Install it in your MLX env:")
        print("  /Users/andreyt/Developer/mlx_env/bin/pip install mlx-lm")
        sys.exit(1)

    # Load existing checkpoint to allow resuming
    existing = load_existing_results()
    already_done = {e["rowid"] for e in existing if e.get("status") == "ok"}
    print(f"Checkpoint: {len(already_done)} entries already processed")

    entries = load_entries(args.start, args.limit)
    entries_to_process = [e for e in entries if e["rowid"] not in already_done]
    print(f"Entries to process: {len(entries_to_process)}")

    if not entries_to_process:
        print("Nothing to do. Use --apply to write results to SQLite.")
        return

    print(f"Loading model from: {MODEL_PATH}")
    model, tokenizer = load(MODEL_PATH)
    print("Model loaded.\n")

    results = list(existing)  # Start from checkpoint
    t0 = time.time()

    for i, entry in enumerate(entries_to_process):
        prompt = build_prompt(entry["word"], entry["original"])

        try:
            response = generate(
                model,
                tokenizer,
                prompt=prompt,
                max_tokens=200,
                verbose=False,
            )
            # Strip trailing whitespace and stop at prompt echo-back markers
            enriched = response.strip()
            for stop in ["\nСлово:", "\nКраткий перевод:", "\n\nСлово"]:
                if stop in enriched:
                    enriched = enriched[:enriched.index(stop)].strip()

            results.append({
                "rowid": entry["rowid"],
                "word": entry["word"],
                "original": entry["original"],
                "enriched": enriched,
                "status": "ok",
            })
        except Exception as exc:
            print(f"  ERROR on '{entry['word']}': {exc}")
            results.append({
                "rowid": entry["rowid"],
                "word": entry["word"],
                "original": entry["original"],
                "enriched": "",
                "status": "error",
                "error": str(exc),
            })

        # Progress
        elapsed = time.time() - t0
        per_entry = elapsed / (i + 1)
        remaining = per_entry * (len(entries_to_process) - i - 1)
        print(
            f"  [{i+1}/{len(entries_to_process)}] {entry['word'][:30]:<30} "
            f"ETA: {remaining/60:.1f} min"
        )

        # Checkpoint
        if (i + 1) % CHECKPOINT_EVERY == 0:
            save_results(results)
            print(f"  ✓ Checkpoint saved ({len(results)} total entries)")

    save_results(results)
    ok = sum(1 for r in results if r.get("status") == "ok")
    print(f"\nDone. {ok}/{len(results)} enriched successfully.")
    print(f"Results: {OUTPUT_JSON}")
    print("\nReview the JSON, then run with --apply to write to SQLite.")


if __name__ == "__main__":
    main()
