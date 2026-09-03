"""Snowball "Russian (Porter)" stemmer, single pass, exactly as published.

MUST stay byte-for-byte equivalent to Shared/RussianStemmer.swift — the bundled
FTS indexes are built with this Python version; the Swift version normalises
queries at runtime. See search_design.md sections 1 and 2 for the full design
rationale (why a single Snowball pass, not iterated to a fixpoint; why not an
ad-hoc suffix stripper; why not NLTagger as the index normaliser).
"""

VOWELS = set("аеиоуыэюяё")
PERFECTIVE_GERUND_1 = ("вшись", "вши", "в")
PERFECTIVE_GERUND_2 = ("ившись", "ывшись", "ивши", "ывши", "ив", "ыв")
ADJECTIVE = ("иями", "ями", "ими", "ыми", "ему", "ому", "его", "ого", "ее", "ие", "ые", "ое",
             "ей", "ий", "ый", "ой", "ем", "им", "ым", "ом", "их", "ых", "ую", "юю", "ая", "яя", "ою", "ею")
PARTICIPLE_1 = ("ющ", "вш", "ем", "нн", "щ")
PARTICIPLE_2 = ("ующ", "ивш", "ывш")
REFLEXIVE = ("ся", "сь")
VERB_1 = ("ешь", "нно", "ете", "йте", "ла", "на", "ли", "ем", "ло", "но", "ет", "ют", "ны", "ть", "й", "л", "н")
VERB_2 = ("ейте", "уйте", "ила", "ыла", "ена", "ите", "или", "ыли", "ило", "ыло", "ено", "ует", "уют",
          "ены", "ить", "ыть", "ишь", "ей", "уй", "ил", "ыл", "им", "ым", "ен", "ят", "ит", "ыт", "ую", "ю")
NOUN = ("иями", "ями", "ами", "иях", "ях", "ах", "ией", "ев", "ов", "ие", "ье", "еи", "ии", "ей", "ой", "ий",
        "иям", "ям", "ием", "ем", "ам", "ом", "ию", "ью", "ия", "ья", "а", "е", "и", "й", "о", "у", "ы", "ь", "ю", "я")
SUPERLATIVE = ("ейше", "ейш")
DERIVATIONAL = ("ость", "ост")


def _rv(w):
    for i, ch in enumerate(w):
        if ch in VOWELS:
            return i + 1
    return len(w)


def _r2(w):
    n, i = len(w), 0
    while i < n - 1 and not (w[i] in VOWELS and w[i + 1] not in VOWELS):
        i += 1
    r1 = i + 2
    i = r1
    while i < n - 1 and not (w[i] in VOWELS and w[i + 1] not in VOWELS):
        i += 1
    return i + 2


def _try(w, start, endings, preceded=None):
    """Longest ending from `endings` ending at len(w), starting at or after `start`.
       Returns the truncated word, or None. With `preceded`, the char immediately
       before the ending must be in `preceded` and is KEPT."""
    for e in sorted(endings, key=len, reverse=True):
        if w.endswith(e) and len(w) - len(e) >= start:
            base = w[:len(w) - len(e)]
            if preceded is not None:
                if base and base[-1] in preceded:
                    return base          # the а/я stays
                continue
            return base
    return None


def stem(word):
    w = word.lower().replace("ё", "е")
    rv, r2 = _rv(w), _r2(w)
    # step 1
    s = _try(w, rv, PERFECTIVE_GERUND_1, preceded="ая")
    if s is None:
        s = _try(w, rv, PERFECTIVE_GERUND_2)
    if s is not None:
        w = s
    else:
        r = _try(w, rv, REFLEXIVE)
        if r is not None:
            w = r
        adj = _try(w, rv, ADJECTIVE)
        if adj is not None:
            w = adj
            p = _try(w, rv, PARTICIPLE_1, preceded="ая")
            if p is None:
                p = _try(w, rv, PARTICIPLE_2)
            if p is not None:
                w = p
        else:
            v = _try(w, rv, VERB_1, preceded="ая")
            if v is None:
                v = _try(w, rv, VERB_2)
            if v is not None:
                w = v
            else:
                n = _try(w, rv, NOUN)
                if n is not None:
                    w = n
    # step 2
    if w.endswith("и") and len(w) - 1 >= rv:
        w = w[:-1]
    # step 3
    d = _try(w, r2, DERIVATIONAL)
    if d is not None:
        w = d
    # step 4
    if w.endswith("нн"):
        w = w[:-1]
    else:
        sup = _try(w, rv, SUPERLATIVE)
        if sup is not None:
            w = sup
            if w.endswith("нн"):
                w = w[:-1]
        elif w.endswith("ь"):
            w = w[:-1]
    return w
