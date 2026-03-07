#!/usr/bin/env python3
"""
pass3_define.py — Generate definitions for biblical words using YandexGPT API.

Reads the Pass 2 summary (lemmas classified as DEFINE) and generates
concise, high-quality definitions with biblical context.
"""

import json
import os
import sys
import time

import openai

from config import (
    PASS2_SUMMARY, PASS3_RESULTS, PASS3_CHECKPOINT, DATA_DIR,
    YANDEX_BASE_URL, YANDEX_FOLDER_ID, YANDEX_TIMEOUT,
    YANDEX_MAX_RETRIES, YANDEX_RETRY_BASE_DELAY, YANDEX_DELAY_BETWEEN_CALLS,
    YANDEX_MAX_TOKENS, yandex_model_uri,
    PASS3_BATCH_SIZE, PASS3_TEMPERATURE, PASS3_MAX_VERSES_PER_WORD,
    DICT_SOURCE,
)

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


def load_summary() -> dict:
    """Load Pass 2 summary."""
    if not PASS2_SUMMARY.exists():
        raise FileNotFoundError(f"Pass 2 summary not found: {PASS2_SUMMARY}\nRun pass2_lemmatize.py first.")
    with open(PASS2_SUMMARY, "r", encoding="utf-8") as f:
        return json.load(f)


def load_checkpoint() -> int:
    """Load checkpoint: returns the index of the next batch to process."""
    if PASS3_CHECKPOINT.exists():
        with open(PASS3_CHECKPOINT, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data.get("next_batch", 0)
    return 0


def save_checkpoint(next_batch: int, total_batches: int):
    """Save checkpoint state."""
    with open(PASS3_CHECKPOINT, "w", encoding="utf-8") as f:
        json.dump({"next_batch": next_batch, "total_batches": total_batches}, f)


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


def run_pass3():
    """Run Pass 3: generate definitions for all DEFINE lemmas."""
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

    # Load Pass 2 summary
    summary = load_summary()
    lemmas = summary["lemmas"]

    # Filter to DEFINE lemmas only
    define_lemmas = {k: v for k, v in lemmas.items() if v.get("cat") == "DEFINE"}
    print(f"Loaded {len(define_lemmas):,} DEFINE lemmas from Pass 2")
    print(f"Model: {yandex_model_uri()}")

    # Sort by frequency (high frequency first)
    sorted_lemmas = sorted(define_lemmas.items(), key=lambda x: -x[1]["freq"])

    # Create batches
    batches = []
    for i in range(0, len(sorted_lemmas), PASS3_BATCH_SIZE):
        batches.append(sorted_lemmas[i:i + PASS3_BATCH_SIZE])

    total_batches = len(batches)
    print(f"Created {total_batches} batches of ~{PASS3_BATCH_SIZE} lemmas")

    # Load checkpoint
    start_batch = load_checkpoint()
    if start_batch > 0:
        print(f"Resuming from batch {start_batch}/{total_batches}")

    # Open results file
    results_mode = "a" if start_batch > 0 else "w"
    results_file = open(PASS3_RESULTS, results_mode, encoding="utf-8")

    total_defined = 0
    total_failed = 0
    total_short = 0
    total_long = 0
    failed_batches = []
    start_time = time.time()

    try:
        for batch_idx in range(start_batch, total_batches):
            batch = batches[batch_idx]
            elapsed = time.time() - start_time
            if batch_idx > start_batch and elapsed > 0:
                rate = (batch_idx - start_batch) / elapsed
                remaining = (total_batches - batch_idx) / rate if rate > 0 else 0
                eta = f"{remaining/60:.1f}min"
            else:
                eta = "..."

            # Progress bar
            pct = (batch_idx + 1) / total_batches * 100
            filled = int(pct / 5)
            bar = "█" * filled + "░" * (20 - filled)
            print(f"\r  [{bar}] {pct:.0f}% ({batch_idx+1}/{total_batches}) "
                  f"defined: {total_defined:,} failed: {total_failed} "
                  f"ETA: {eta}", end="", flush=True)

            # Build prompt for this batch
            entries_str = "\n\n".join(
                format_word_entry(lemma_key, info)
                for lemma_key, info in batch
            )

            results = call_api(client, entries_str)

            if not results:
                failed_batches.append(batch_idx)
                total_failed += len(batch)
                for lemma_key, info in batch:
                    results_file.write(json.dumps({
                        "lemma": info["display"],
                        "definition": "",
                        "status": "FAILED",
                        "batch": batch_idx,
                    }, ensure_ascii=False) + "\n")
            else:
                for r in results:
                    defn = r.get("definition", "").strip()
                    lemma = r.get("lemma", "").strip()

                    status = "OK"
                    if not defn:
                        status = "EMPTY"
                        total_failed += 1
                    elif len(defn) < 15:
                        status = "SHORT"
                        total_short += 1
                    elif len(defn) > 400:
                        status = "LONG"
                        total_long += 1

                    if defn:
                        total_defined += 1

                    results_file.write(json.dumps({
                        "lemma": lemma,
                        "definition": defn,
                        "status": status,
                        "batch": batch_idx,
                    }, ensure_ascii=False) + "\n")

            results_file.flush()
            save_checkpoint(batch_idx + 1, total_batches)

            # Rate limiting delay
            time.sleep(YANDEX_DELAY_BETWEEN_CALLS)

    except KeyboardInterrupt:
        print(f"\n\nInterrupted at batch {batch_idx}. Progress saved. Resume with same command.")
    finally:
        results_file.close()

    elapsed = time.time() - start_time
    print(f"\n\n✓ Pass 3 complete in {elapsed/60:.1f} minutes")
    print(f"  Defined: {total_defined:,}")
    if total_short > 0:
        print(f"  Short (<15 chars): {total_short:,}")
    if total_long > 0:
        print(f"  Long (>400 chars): {total_long:,}")
    if total_failed > 0:
        print(f"  Failed/empty: {total_failed:,} (batches: {failed_batches})")
    print(f"  Results: {PASS3_RESULTS}")


if __name__ == "__main__":
    run_pass3()
