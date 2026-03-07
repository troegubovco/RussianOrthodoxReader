#!/usr/bin/env python3
"""
pass3_retry.py — Retry definitions for DEFINE lemmas that are missing or failed.

Compares pass2_summary.json (all DEFINE lemmas) against pass3_definitions.jsonl
(existing results) and re-processes any gaps. Appends new results to the jsonl.
After running, re-run pass4_build_sqlite.py to rebuild the database.
"""

import json
import os
import sys
import time

import openai

from config import (
    PASS2_SUMMARY, PASS3_RESULTS, DATA_DIR,
    YANDEX_BASE_URL, YANDEX_FOLDER_ID,
    YANDEX_MAX_RETRIES, YANDEX_RETRY_BASE_DELAY, YANDEX_DELAY_BETWEEN_CALLS,
    YANDEX_MAX_TOKENS, yandex_model_uri,
    PASS3_TEMPERATURE, PASS3_MAX_VERSES_PER_WORD,
)

# Smaller batches for retry — fewer words = better accuracy
RETRY_BATCH_SIZE = 5

SYSTEM_PROMPT = "Ты — лексикограф. Составляешь краткий толковый словарь. Для каждого слова пишешь определение в 1–3 предложения. Отвечаешь в формате JSON-массива."

USER_PROMPT_TEMPLATE = """Напиши краткое определение (1–3 предложения) для каждого слова. Начинай с современного эквивалента или краткого пояснения. Для имён — кто это и чем известен. Для мер — современный эквивалент.

Пример ответа:
[
  {{"lemma": "вретище", "definition": "Грубая одежда из мешковины или волосяной ткани. Надевалась в знак скорби, траура и покаяния."}},
  {{"lemma": "десница", "definition": "Правая рука. В переносном смысле — символ силы и власти."}},
  {{"lemma": "Авраам", "definition": "Праотец, родоначальник еврейского народа. Призван из Ура Халдейского, получил обетование о многочисленном потомстве."}}
]

Слова для определения (с контекстом):
{word_entries}"""


def format_word_entry(lemma_key: str, info: dict) -> str:
    """Format a single word entry for the prompt."""
    display = info["display"]
    wtype = info.get("type", "")
    refs = info.get("refs", [])

    lines = [f'- {display} (тип: {wtype or "общее"}, частота: {info["freq"]})']
    for ref in refs[:PASS3_MAX_VERSES_PER_WORD]:
        book_id, ch, vs, text = ref
        if len(text) > 120:
            text = text[:120] + "..."
        lines.append(f'  «{text}» ({book_id} {ch}:{vs})')

    return "\n".join(lines)


def find_missing_lemmas() -> list[tuple[str, dict]]:
    """Find DEFINE lemmas that are missing or failed in pass3 results."""
    # Load pass2 summary
    with open(PASS2_SUMMARY, "r", encoding="utf-8") as f:
        summary = json.load(f)
    lemmas = summary["lemmas"]

    define_lemmas = {k: v for k, v in lemmas.items() if v.get("cat") == "DEFINE"}
    print(f"Total DEFINE lemmas in Pass 2: {len(define_lemmas):,}")

    # Load existing pass3 results — find which lemmas have good definitions
    defined_lemmas = set()
    if PASS3_RESULTS.exists():
        with open(PASS3_RESULTS, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue

                lemma = r.get("lemma", "").strip()
                defn = r.get("definition", "").strip()
                status = r.get("status", "")

                if lemma and defn and status not in ("FAILED", "EMPTY"):
                    defined_lemmas.add(lemma.lower())

    print(f"Already defined: {len(defined_lemmas):,}")

    # Find missing
    missing = []
    for lemma_key, info in define_lemmas.items():
        if lemma_key not in defined_lemmas:
            missing.append((lemma_key, info))

    # Sort by frequency (highest first)
    missing.sort(key=lambda x: -x[1]["freq"])

    print(f"Missing/failed: {len(missing):,}")
    if missing:
        top = [m[1]["display"] for m in missing[:10]]
        print(f"  Top missing: {', '.join(top)}")

    return missing


def call_api(client: openai.OpenAI, word_entries_str: str) -> list[dict]:
    """Call YandexGPT via OpenAI Responses API. Returns parsed definitions."""
    user_prompt = USER_PROMPT_TEMPLATE.format(word_entries=word_entries_str)

    for attempt in range(YANDEX_MAX_RETRIES):
        try:
            response = client.responses.create(
                model=yandex_model_uri(),
                instructions=SYSTEM_PROMPT,
                input=user_prompt,
                temperature=PASS3_TEMPERATURE,
                max_output_tokens=YANDEX_MAX_TOKENS,
            )
            content = response.output_text.strip()

            # Handle potential markdown wrapping
            if content.startswith("```"):
                lines = content.split("\n")
                lines = [l for l in lines if not l.strip().startswith("```")]
                content = "\n".join(lines)

            # Find JSON array in the response
            start = content.find("[")
            end = content.rfind("]")
            if start != -1 and end != -1:
                content = content[start:end + 1]

            results = json.loads(content)
            if not isinstance(results, list):
                raise ValueError(f"Expected JSON array, got {type(results)}")
            return results

        except json.JSONDecodeError as e:
            print(f"\n  JSON parse error (attempt {attempt+1}): {e}")
            if attempt < YANDEX_MAX_RETRIES - 1:
                delay = YANDEX_RETRY_BASE_DELAY * (2 ** attempt)
                print(f"  Retrying in {delay:.0f}s...")
                time.sleep(delay)
            else:
                print(f"  FAILED after {YANDEX_MAX_RETRIES} attempts.")
                try:
                    print(f"  Response preview: {content[:300]}")
                except:
                    print(f"  (could not display response)")
                return []

        except openai.RateLimitError as e:
            delay = YANDEX_RETRY_BASE_DELAY * (4 ** attempt)
            print(f"\n  Rate limited (attempt {attempt+1}). Waiting {delay:.0f}s...")
            time.sleep(delay)

        except (openai.APIError, openai.APIConnectionError) as e:
            print(f"\n  API error (attempt {attempt+1}): {e}")
            if attempt < YANDEX_MAX_RETRIES - 1:
                delay = YANDEX_RETRY_BASE_DELAY * (2 ** attempt)
                print(f"  Retrying in {delay:.0f}s...")
                time.sleep(delay)
            else:
                print(f"  FAILED after {YANDEX_MAX_RETRIES} attempts: {e}")
                return []

        except Exception as e:
            print(f"\n  Unexpected error (attempt {attempt+1}): {e}")
            if attempt < YANDEX_MAX_RETRIES - 1:
                delay = YANDEX_RETRY_BASE_DELAY * (2 ** attempt)
                print(f"  Retrying in {delay:.0f}s...")
                time.sleep(delay)
            else:
                print(f"  FAILED after {YANDEX_MAX_RETRIES} attempts: {e}")
                return []

    return []


def run_retry():
    """Retry definitions for missing/failed lemmas."""
    api_key = os.environ.get("YANDEX_API_KEY")
    if not api_key:
        print("Error: YANDEX_API_KEY environment variable not set.")
        print("  export YANDEX_API_KEY='your-api-key-here'")
        sys.exit(1)

    client = openai.OpenAI(
        api_key=api_key,
        base_url=YANDEX_BASE_URL,
        project=YANDEX_FOLDER_ID,
    )

    # Find what's missing
    missing = find_missing_lemmas()
    if not missing:
        print("\n✓ No missing definitions! All DEFINE lemmas have definitions.")
        return

    # Create batches
    batches = []
    for i in range(0, len(missing), RETRY_BATCH_SIZE):
        batches.append(missing[i:i + RETRY_BATCH_SIZE])

    total_batches = len(batches)
    print(f"\nRetrying {len(missing):,} lemmas in {total_batches} batches of ≤{RETRY_BATCH_SIZE}")
    print(f"Model: {yandex_model_uri()}")

    # Append results to existing file
    results_file = open(PASS3_RESULTS, "a", encoding="utf-8")

    total_defined = 0
    total_failed = 0
    still_missing = []
    start_time = time.time()

    try:
        for batch_idx, batch in enumerate(batches):
            elapsed = time.time() - start_time
            if batch_idx > 0 and elapsed > 0:
                rate = batch_idx / elapsed
                remaining = (total_batches - batch_idx) / rate if rate > 0 else 0
                eta = f"{remaining/60:.1f}min"
            else:
                eta = "..."

            pct = (batch_idx + 1) / total_batches * 100
            filled = int(pct / 5)
            bar = "█" * filled + "░" * (20 - filled)
            print(f"\r  [{bar}] {pct:.0f}% ({batch_idx+1}/{total_batches}) "
                  f"recovered: {total_defined} failed: {total_failed} "
                  f"ETA: {eta}", end="", flush=True)

            entries_str = "\n\n".join(
                format_word_entry(lemma_key, info)
                for lemma_key, info in batch
            )

            results = call_api(client, entries_str)

            if not results:
                total_failed += len(batch)
                for lemma_key, info in batch:
                    still_missing.append(info["display"])
                    results_file.write(json.dumps({
                        "lemma": info["display"],
                        "definition": "",
                        "status": "RETRY_FAILED",
                        "batch": f"retry_{batch_idx}",
                    }, ensure_ascii=False) + "\n")
            else:
                returned_lemmas = {r.get("lemma", "").lower() for r in results}
                for r in results:
                    defn = r.get("definition", "").strip()
                    lemma = r.get("lemma", "").strip()

                    if defn:
                        total_defined += 1
                        status = "OK"
                    else:
                        total_failed += 1
                        still_missing.append(lemma)
                        status = "EMPTY"

                    results_file.write(json.dumps({
                        "lemma": lemma,
                        "definition": defn,
                        "status": status,
                        "batch": f"retry_{batch_idx}",
                    }, ensure_ascii=False) + "\n")

                # Check for words the API silently dropped
                for lemma_key, info in batch:
                    if lemma_key not in returned_lemmas:
                        still_missing.append(info["display"])
                        total_failed += 1
                        results_file.write(json.dumps({
                            "lemma": info["display"],
                            "definition": "",
                            "status": "DROPPED",
                            "batch": f"retry_{batch_idx}",
                        }, ensure_ascii=False) + "\n")

            results_file.flush()
            time.sleep(YANDEX_DELAY_BETWEEN_CALLS)

    except KeyboardInterrupt:
        print(f"\n\nInterrupted at batch {batch_idx}.")
    finally:
        results_file.close()

    elapsed = time.time() - start_time
    print(f"\n\n✓ Retry complete in {elapsed/60:.1f} minutes")
    print(f"  Recovered: {total_defined:,}")
    print(f"  Still failed: {total_failed:,}")
    if still_missing:
        show = still_missing[:20]
        print(f"  Still missing: {', '.join(show)}")
        if len(still_missing) > 20:
            print(f"    ... and {len(still_missing) - 20} more")
    print(f"\nRun pass4_build_sqlite.py to rebuild the dictionary.")


if __name__ == "__main__":
    run_retry()
