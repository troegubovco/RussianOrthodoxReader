#!/usr/bin/env python3
"""
apply_manual_definitions.py — Append hand-written definitions to pass3_definitions.jsonl,
then rebuild the SQLite dictionary.
"""

import json
from pathlib import Path

from manual_definitions import DEFINITIONS
from manual_definitions_p2 import DEFINITIONS_P2
from manual_definitions_p3 import DEFINITIONS_P3
from config import PASS3_RESULTS, PASS2_SUMMARY

def main():
    # Merge all definitions
    all_defs = {}
    all_defs.update(DEFINITIONS)
    all_defs.update(DEFINITIONS_P2)
    all_defs.update(DEFINITIONS_P3)
    print(f"Manual definitions loaded: {len(all_defs)}")

    # Load pass2 summary to find exact display names
    with open(PASS2_SUMMARY, "r", encoding="utf-8") as f:
        summary = json.load(f)
    lemmas = summary["lemmas"]

    # Build lookup: lowercase -> pass2 display name
    pass2_display = {}
    for k, v in lemmas.items():
        pass2_display[k] = v.get("display", k)

    # Load existing pass3 results to find what's already defined
    existing = set()
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
                if lemma and defn and status not in ("FAILED", "EMPTY", "RETRY_FAILED", "DROPPED"):
                    existing.add(lemma.lower())

    print(f"Already defined in pass3: {len(existing)}")

    # Match manual definitions to missing lemmas
    appended = 0
    skipped = 0
    with open(PASS3_RESULTS, "a", encoding="utf-8") as f:
        for word, defn in all_defs.items():
            key = word.strip().lower()
            if key in existing:
                skipped += 1
                continue

            # Use pass2 display name if available
            display = pass2_display.get(key, word.strip())

            f.write(json.dumps({
                "lemma": display,
                "definition": defn,
                "status": "OK",
                "batch": "manual",
            }, ensure_ascii=False) + "\n")
            appended += 1

    print(f"Appended: {appended}")
    print(f"Skipped (already defined): {skipped}")
    print(f"\nNow run: python3 pass4_build_sqlite.py")

if __name__ == "__main__":
    main()
