#!/usr/bin/env python3
"""
pass2_lemmatize.py — Lemmatize and classify words using YandexGPT 5 Pro
via the OpenAI-compatible Responses API.

For each word from Pass 1, determines:
  - The lemma (dictionary form)
  - Category: DEFINE (needs dictionary entry) or SKIP (common modern word)
  - Type tag: архаизм, имя собственное, etc.
"""

import json
import os
import sys
import time
from collections import defaultdict

import openai

from config import (
    PASS1_OUTPUT, PASS2_RESULTS, PASS2_CHECKPOINT, PASS2_SUMMARY,
    DATA_DIR, YANDEX_BASE_URL, YANDEX_FOLDER_ID, YANDEX_TIMEOUT,
    YANDEX_MAX_RETRIES, YANDEX_RETRY_BASE_DELAY, YANDEX_DELAY_BETWEEN_CALLS,
    YANDEX_MAX_TOKENS, yandex_model_uri,
    PASS2_BATCH_SIZE, PASS2_TEMPERATURE,
)

INSTRUCTIONS = "Ты — лингвист. Анализируешь слова из литературного корпуса XIX века. Для каждого слова определяешь начальную форму (лемму), категорию (DEFINE — нужно толкование, SKIP — не нужно) и тип. Отвечаешь в формате JSON-массива."

USER_PROMPT_TEMPLATE = """Определи лемму и категорию для каждого слова. Частота указана в скобках.

Категории:
- DEFINE — архаизм, историзм, имя собственное, устаревшее, термин, мера/монета, реалия
- SKIP — обычное современное слово, понятное без пояснения

Для имён собственных лемма с заглавной буквы. Тип указывай для DEFINE.

Пример ответа:
[
  {{"form": "вретище", "lemma": "вретище", "cat": "DEFINE", "type": "архаизм"}},
  {{"form": "народа", "lemma": "народ", "cat": "SKIP", "type": ""}},
  {{"form": "десницу", "lemma": "десница", "cat": "DEFINE", "type": "архаизм"}},
  {{"form": "авраама", "lemma": "Авраам", "cat": "DEFINE", "type": "имя (лицо)"}},
  {{"form": "дома", "lemma": "дом", "cat": "SKIP", "type": ""}}
]

Слова для анализа:
{word_list}"""


def load_pass1_words() -> dict:
    """Load Pass 1 output."""
    if not PASS1_OUTPUT.exists():
        raise FileNotFoundError(f"Pass 1 output not found: {PASS1_OUTPUT}\nRun pass1_extract.py first.")
    with open(PASS1_OUTPUT, "r", encoding="utf-8") as f:
        return json.load(f)


def load_checkpoint() -> int:
    """Load checkpoint: returns the index of the next batch to process."""
    if PASS2_CHECKPOINT.exists():
        with open(PASS2_CHECKPOINT, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data.get("next_batch", 0)
    return 0


def save_checkpoint(next_batch: int, total_batches: int):
    """Save checkpoint state."""
    with open(PASS2_CHECKPOINT, "w", encoding="utf-8") as f:
        json.dump({"next_batch": next_batch, "total_batches": total_batches}, f)


def call_api(client: openai.OpenAI, word_batch: list[tuple[str, int]]) -> list[dict]:
    """Call YandexGPT via OpenAI Responses API. Returns parsed results."""
    word_list_str = "\n".join(f'"{w}" ({c})' for w, c in word_batch)
    user_prompt = USER_PROMPT_TEMPLATE.format(word_list=word_list_str)

    for attempt in range(YANDEX_MAX_RETRIES):
        try:
            response = client.responses.create(
                model=yandex_model_uri(),
                instructions=INSTRUCTIONS,
                input=user_prompt,
                temperature=PASS2_TEMPERATURE,
                max_output_tokens=YANDEX_MAX_TOKENS,
            )
            content = response.output_text.strip()

            # Handle potential markdown wrapping
            if content.startswith("```"):
                lines = content.split("\n")
                lines = [l for l in lines if not l.strip().startswith("```")]
                content = "\n".join(lines)

            # Find JSON array in response
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
                print(f"  FAILED after {YANDEX_MAX_RETRIES} attempts. Raw response:")
                try:
                    print(f"  {content[:500]}")
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


def run_pass2():
    """Run Pass 2: lemmatize and classify all words."""
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

    # Load Pass 1 data
    data = load_pass1_words()
    words = data["words"]
    print(f"Loaded {len(words):,} words from Pass 1")

    # Sort by frequency (process high-frequency words first)
    sorted_words = sorted(words.items(), key=lambda x: -x[1]["count"])
    word_freq_list = [(w, info["count"]) for w, info in sorted_words]

    # Create batches
    batches = []
    for i in range(0, len(word_freq_list), PASS2_BATCH_SIZE):
        batches.append(word_freq_list[i:i + PASS2_BATCH_SIZE])

    total_batches = len(batches)
    print(f"Created {total_batches} batches of ~{PASS2_BATCH_SIZE} words")
    print(f"Model: {yandex_model_uri()}")

    # Load checkpoint
    start_batch = load_checkpoint()
    if start_batch > 0:
        print(f"Resuming from batch {start_batch}/{total_batches}")

    # Open results file in append mode
    results_mode = "a" if start_batch > 0 else "w"
    results_file = open(PASS2_RESULTS, results_mode, encoding="utf-8")

    total_define = 0
    total_skip = 0
    total_failed = 0
    failed_batches = []
    start_time = time.time()

    try:
        for batch_idx in range(start_batch, total_batches):
            batch = batches[batch_idx]
            elapsed = time.time() - start_time
            if batch_idx > start_batch:
                rate = (batch_idx - start_batch) / elapsed
                remaining = (total_batches - batch_idx) / rate if rate > 0 else 0
                eta = f"{remaining/60:.1f}min"
            else:
                eta = "..."

            # Progress bar
            pct = (batch_idx + 1) / total_batches * 100
            filled = int(pct / 5)
            bar = "█" * filled + "░" * (20 - filled)
            words_done = min((batch_idx + 1) * PASS2_BATCH_SIZE, len(word_freq_list))
            print(f"\r  [{bar}] {pct:.0f}% ({batch_idx+1}/{total_batches}) "
                  f"words: {words_done:,}/{len(word_freq_list):,} "
                  f"DEFINE: {total_define:,} SKIP: {total_skip:,} "
                  f"ETA: {eta}", end="", flush=True)

            results = call_api(client, batch)

            if not results:
                failed_batches.append(batch_idx)
                total_failed += len(batch)
                for w, c in batch:
                    results_file.write(json.dumps(
                        {"form": w, "lemma": w, "cat": "UNKNOWN", "type": "", "batch": batch_idx},
                        ensure_ascii=False
                    ) + "\n")
            else:
                for r in results:
                    cat = r.get("cat", "SKIP")
                    if cat == "DEFINE":
                        total_define += 1
                    else:
                        total_skip += 1
                    r["batch"] = batch_idx
                    results_file.write(json.dumps(r, ensure_ascii=False) + "\n")

            results_file.flush()
            save_checkpoint(batch_idx + 1, total_batches)

            # Rate limiting delay
            time.sleep(YANDEX_DELAY_BETWEEN_CALLS)

    except KeyboardInterrupt:
        print(f"\n\nInterrupted at batch {batch_idx}. Progress saved. Resume with same command.")
    finally:
        results_file.close()

    elapsed = time.time() - start_time
    print(f"\n\n✓ Pass 2 complete in {elapsed/60:.1f} minutes")
    print(f"  DEFINE: {total_define:,}")
    print(f"  SKIP: {total_skip:,}")
    if total_failed > 0:
        print(f"  FAILED: {total_failed:,} (batches: {failed_batches})")
    print(f"  Results: {PASS2_RESULTS}")

    # Build summary
    build_summary()


def build_summary():
    """Post-process Pass 2 results: group forms by lemma, aggregate stats."""
    if not PASS2_RESULTS.exists():
        print("No Pass 2 results to summarize.")
        return

    # Load Pass 1 for verse refs
    data = load_pass1_words()
    pass1_words = data["words"]

    # Load all Pass 2 results
    lemma_forms: dict[str, list[str]] = defaultdict(list)
    lemma_cat: dict[str, str] = {}
    lemma_type: dict[str, str] = {}
    display_lemmas: dict[str, str] = {}

    with open(PASS2_RESULTS, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue

            form = r.get("form", "").lower()
            lemma_raw = r.get("lemma", form)
            lemma = lemma_raw.lower()
            cat = r.get("cat", "SKIP")
            wtype = r.get("type", "")

            if not form:
                continue

            lemma_forms[lemma].append(form)

            if lemma_raw and lemma_raw[0].isupper():
                display_lemmas[lemma] = lemma_raw

            if cat == "DEFINE":
                lemma_cat[lemma] = "DEFINE"
                if wtype and (lemma not in lemma_type or not lemma_type[lemma]):
                    lemma_type[lemma] = wtype
            elif lemma not in lemma_cat:
                lemma_cat[lemma] = cat

    # Build summary with verse refs
    summary = {
        "meta": {
            "total_lemmas": len(lemma_forms),
            "define_count": sum(1 for l in lemma_cat.values() if l == "DEFINE"),
            "skip_count": sum(1 for l in lemma_cat.values() if l == "SKIP"),
            "unknown_count": sum(1 for l in lemma_cat.values() if l == "UNKNOWN"),
        },
        "lemmas": {},
    }

    for lemma, forms in lemma_forms.items():
        unique_forms = sorted(set(forms))
        cat = lemma_cat.get(lemma, "SKIP")

        total_freq = sum(pass1_words.get(f, {}).get("count", 0) for f in unique_forms)

        all_refs = []
        for f in unique_forms:
            refs = pass1_words.get(f, {}).get("refs", [])
            all_refs.extend(refs)

        seen_books = set()
        best_refs = []
        for ref in all_refs:
            book = ref[0]
            if book not in seen_books and len(best_refs) < 3:
                best_refs.append(ref)
                seen_books.add(book)
        for ref in all_refs:
            if len(best_refs) >= 3:
                break
            if ref not in best_refs:
                best_refs.append(ref)

        display = display_lemmas.get(lemma, lemma)

        summary["lemmas"][lemma] = {
            "display": display,
            "cat": cat,
            "type": lemma_type.get(lemma, ""),
            "forms": unique_forms,
            "freq": total_freq,
            "refs": best_refs[:3],
        }

    with open(PASS2_SUMMARY, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)

    print(f"\n✓ Summary saved to {PASS2_SUMMARY}")
    print(f"  Total lemmas: {summary['meta']['total_lemmas']:,}")
    print(f"  DEFINE: {summary['meta']['define_count']:,}")
    print(f"  SKIP: {summary['meta']['skip_count']:,}")
    if summary['meta']['unknown_count'] > 0:
        print(f"  UNKNOWN (failed): {summary['meta']['unknown_count']:,}")


if __name__ == "__main__":
    if "--summary-only" in sys.argv:
        build_summary()
    else:
        run_pass2()
