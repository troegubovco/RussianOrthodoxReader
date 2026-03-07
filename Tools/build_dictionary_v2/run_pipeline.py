#!/usr/bin/env python3
"""
run_pipeline.py — Orchestrator for the dictionary generation pipeline.

Usage:
    python3 run_pipeline.py              # Run all passes
    python3 run_pipeline.py --from pass2 # Resume from pass 2
    python3 run_pipeline.py --only pass1 # Run only pass 1
    python3 run_pipeline.py --dry-run    # Show stats without API calls
    python3 run_pipeline.py --clean      # Remove all intermediate data
"""

import argparse
import shutil
import sys
import time
from pathlib import Path

from config import DATA_DIR, PASS1_OUTPUT, PASS2_SUMMARY, PASS3_RESULTS, OUTPUT_DB


def run_pass1():
    """Run Pass 1: word extraction."""
    print("\n" + "=" * 60)
    print("PASS 1 — Word Extraction (no API)")
    print("=" * 60 + "\n")
    from pass1_extract import extract_words
    extract_words()


def run_pass2():
    """Run Pass 2: lemmatization + classification."""
    print("\n" + "=" * 60)
    print("PASS 2 — Lemmatization + Classification (xAI API)")
    print("=" * 60 + "\n")
    from pass2_lemmatize import run_pass2 as _run
    _run()


def run_pass3():
    """Run Pass 3: definition generation."""
    print("\n" + "=" * 60)
    print("PASS 3 — Definition Generation (xAI API)")
    print("=" * 60 + "\n")
    from pass3_define import run_pass3 as _run
    _run()


def run_pass4():
    """Run Pass 4: build SQLite."""
    print("\n" + "=" * 60)
    print("PASS 4 — Build SQLite Database")
    print("=" * 60 + "\n")
    from pass4_build_sqlite import build_database
    build_database()


def dry_run():
    """Show current state and estimates without running anything."""
    import json

    print("\n── Pipeline Status ──\n")

    # Pass 1
    if PASS1_OUTPUT.exists():
        with open(PASS1_OUTPUT, "r", encoding="utf-8") as f:
            data = json.load(f)
        meta = data["meta"]
        print(f"Pass 1: ✓ Complete")
        print(f"  Words: {meta['unique_forms_filtered']:,} (from {meta['verse_count']:,} verses)")
        print(f"  Stopwords removed: {meta['stopwords_removed']:,}")
    else:
        print(f"Pass 1: ✗ Not started")

    # Pass 2
    if PASS2_SUMMARY.exists():
        with open(PASS2_SUMMARY, "r", encoding="utf-8") as f:
            summary = json.load(f)
        meta = summary["meta"]
        print(f"\nPass 2: ✓ Complete")
        print(f"  Lemmas: {meta['total_lemmas']:,}")
        print(f"  DEFINE: {meta['define_count']:,}")
        print(f"  SKIP: {meta['skip_count']:,}")
    else:
        from config import PASS2_CHECKPOINT
        if PASS2_CHECKPOINT.exists():
            with open(PASS2_CHECKPOINT, "r", encoding="utf-8") as f:
                cp = json.load(f)
            print(f"\nPass 2: ⏸  In progress ({cp['next_batch']}/{cp['total_batches']} batches)")
        else:
            print(f"\nPass 2: ✗ Not started")

    # Pass 3
    if PASS3_RESULTS.exists():
        count = 0
        ok_count = 0
        with open(PASS3_RESULTS, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    count += 1
                    try:
                        r = json.loads(line.strip())
                        if r.get("status") == "OK" and r.get("definition"):
                            ok_count += 1
                    except:
                        pass
        from config import PASS3_CHECKPOINT
        if PASS3_CHECKPOINT.exists():
            with open(PASS3_CHECKPOINT, "r", encoding="utf-8") as f:
                cp = json.load(f)
            done = cp["next_batch"] >= cp["total_batches"]
            status = "✓ Complete" if done else f"⏸  In progress ({cp['next_batch']}/{cp['total_batches']})"
        else:
            status = "✓ Has results"
        print(f"\nPass 3: {status}")
        print(f"  Total results: {count:,}")
        print(f"  OK definitions: {ok_count:,}")
    else:
        print(f"\nPass 3: ✗ Not started")

    # Pass 4
    if OUTPUT_DB.exists():
        import sqlite3
        con = sqlite3.connect(str(OUTPUT_DB))
        cur = con.cursor()
        cur.execute("SELECT COUNT(*) FROM entries")
        entries = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM conjugations")
        conjs = cur.fetchone()[0]
        con.close()
        size_mb = OUTPUT_DB.stat().st_size / (1024 * 1024)
        print(f"\nPass 4 / Output DB: ✓ Complete")
        print(f"  Entries: {entries:,}")
        print(f"  Conjugations: {conjs:,}")
        print(f"  Size: {size_mb:.2f} MB")
    else:
        print(f"\nPass 4: ✗ Not built yet")

    # Estimates
    if PASS1_OUTPUT.exists() and not PASS2_SUMMARY.exists():
        from config import PASS2_BATCH_SIZE
        with open(PASS1_OUTPUT, "r", encoding="utf-8") as f:
            data = json.load(f)
        word_count = data["meta"]["unique_forms_filtered"]
        batches = (word_count + PASS2_BATCH_SIZE - 1) // PASS2_BATCH_SIZE
        print(f"\n── Estimates for remaining passes ──")
        print(f"  Pass 2: ~{batches} API calls")
        print(f"  Pass 3: depends on DEFINE count (est. 150-350 API calls)")


def clean():
    """Remove all intermediate data."""
    if DATA_DIR.exists():
        shutil.rmtree(DATA_DIR)
        print(f"Removed {DATA_DIR}")
    else:
        print("Nothing to clean")


def main():
    parser = argparse.ArgumentParser(description="Biblical dictionary generation pipeline")
    parser.add_argument("--from", dest="from_pass", choices=["pass1", "pass2", "pass3", "pass4"],
                        help="Start from a specific pass")
    parser.add_argument("--only", choices=["pass1", "pass2", "pass3", "pass4"],
                        help="Run only a specific pass")
    parser.add_argument("--dry-run", action="store_true", help="Show status and estimates")
    parser.add_argument("--clean", action="store_true", help="Remove intermediate data")

    args = parser.parse_args()

    if args.clean:
        clean()
        return

    if args.dry_run:
        dry_run()
        return

    passes = {
        "pass1": run_pass1,
        "pass2": run_pass2,
        "pass3": run_pass3,
        "pass4": run_pass4,
    }
    pass_order = ["pass1", "pass2", "pass3", "pass4"]

    if args.only:
        print(f"Running only {args.only}")
        passes[args.only]()
        return

    start_idx = 0
    if args.from_pass:
        start_idx = pass_order.index(args.from_pass)
        print(f"Starting from {args.from_pass}")

    start_time = time.time()
    for i in range(start_idx, len(pass_order)):
        passes[pass_order[i]]()

    elapsed = time.time() - start_time
    print(f"\n{'=' * 60}")
    print(f"Pipeline complete in {elapsed/60:.1f} minutes")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
