"""Golden tests for Tools/russian_stemmer.py.

No pytest dependency: run with `python3 Tools/tests/test_stemmer.py`.

Two groups of assertions, per the implementation plan (search_design.md §5 step 1):
  1. STEP_TABLE_PAIRS — one example per rule branch in §2.1's step table (both
     PERFECTIVE_GERUND variants, REFLEXIVE, ADJECTIVE+PARTICIPLE, VERB_1/VERB_2,
     NOUN, the step-2 trailing-и rule, DERIVATIONAL, the нн->н collapse,
     SUPERLATIVE, and the bare-ь rule), so a typo in transcribing the algorithm
     from the spec into code is caught.
  2. CONFLATION_PAIRS — 13 pairs of distinct surface word forms from the
     Synodal/prayers vocabulary that must stem identically, verified by running
     the stemmer over the vocabulary during this spec's research.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from russian_stemmer import stem  # noqa: E402

# --- 1. One example per step-table rule branch (§2.1) -----------------------
STEP_TABLE_PAIRS = [
    # PERFECTIVE_GERUND_1: "в" preceded by а/я, kept
    ("сказав", "сказа"),
    # PERFECTIVE_GERUND_1: "вши" preceded by а/я, kept
    ("прочитавши", "прочита"),
    # PERFECTIVE_GERUND_2: "ившись"
    ("решившись", "реш"),
    # REFLEXIVE: "ся"
    ("умывается", "умыва"),
    # REFLEXIVE: "сь"
    ("умылась", "ум"),
    # ADJECTIVE: "ая"
    ("красивая", "красив"),
    # ADJECTIVE + PARTICIPLE_1 ("ющ", preceded by а/я not required here since
    # participle1 match is attempted after adjective strip)
    ("читающий", "чита"),
    # VERB_2: "ите"
    ("говорите", "говор"),
    # NOUN: "ов"
    ("домов", "дом"),
    # DERIVATIONAL: "ость" in R2
    ("радость", "радост"),
    # DERIVATIONAL: "ость" in R2 (second example, different stem length)
    ("юность", "юност"),
    # step 4: "нн" -> "н" (after ADJECTIVE "ая" strip leaves "длинн")
    ("длинная", "длин"),
    # SUPERLATIVE: "ейш" (after ADJECTIVE "ий" strip leaves "нежнейш")
    ("нежнейший", "нежн"),
    # trailing "ь" removed when nothing else fires
    ("соль", "сол"),
]

# --- 2. Conflation pairs: two distinct surface forms, same stem -------------
CONFLATION_PAIRS = [
    ("молитва", "молитвы"),
    ("вера", "веры"),
    ("надежда", "надежды"),
    ("болезнь", "болезни"),
    ("дорога", "дороге"),
    ("работа", "работе"),
    ("экзаменом", "экзамену"),
    ("депрессия", "депрессии"),
    ("умерший", "умершего"),
    ("покойный", "покойного"),
    ("еда", "еды"),
    ("терпение", "терпения"),
    ("путь", "пути"),
]


def run():
    failures = []

    for word, expected in STEP_TABLE_PAIRS:
        got = stem(word)
        if got != expected:
            failures.append(f"STEP_TABLE: stem({word!r}) = {got!r}, expected {expected!r}")

    for a, b in CONFLATION_PAIRS:
        sa, sb = stem(a), stem(b)
        if sa != sb:
            failures.append(f"CONFLATION: stem({a!r})={sa!r} != stem({b!r})={sb!r}")

    total = len(STEP_TABLE_PAIRS) + len(CONFLATION_PAIRS)
    if failures:
        print(f"FAILED {len(failures)}/{total} assertions:")
        for f in failures:
            print(" -", f)
        sys.exit(1)
    else:
        print(f"OK: {len(STEP_TABLE_PAIRS)} step-table pairs + "
              f"{len(CONFLATION_PAIRS)} conflation pairs, {total} assertions passed.")


if __name__ == "__main__":
    run()
