#!/usr/bin/env python3
"""
Build church_names.sqlite from Tools/data/church_names.json.

Generates genitive/accusative/dative forms of canonical church names using
Russian first-name declension rules plus an OVERRIDES table for irregulars.
Prints every generated form for eyeball review — proofread before shipping.

Output: RussianOrthodoxReader/Resources/church_names.sqlite

Usage:
    python3 Tools/build_names_db.py
"""
import json
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
JSON_PATH = os.path.join(SCRIPT_DIR, "data", "church_names.json")
DB_PATH = os.path.join(PROJECT_ROOT, "RussianOrthodoxReader", "Resources", "church_names.sqlite")

# Неправильные формы: canonical → (gen, acc, dat)
OVERRIDES = {
    "Лев":     ("Льва", "Льва", "Льву"),
    "Павел":   ("Павла", "Павла", "Павлу"),
    "Петр":    ("Петра", "Петра", "Петру"),
    "Любовь":  ("Любови", "Любовь", "Любови"),
}

# После этих согласных родительный жен. имён на -а даёт -и (а не -ы)
HUSHING_OR_VELAR = set("гкхжчшщ")

VOWELS = set("аеёиоуыэюя")


def decline(name: str, gender: str) -> tuple[str, str, str]:
    """Возвращает (родительный, винительный, дательный)."""
    if name in OVERRIDES:
        return OVERRIDES[name]

    if gender == "m":
        if name.endswith("ий"):
            stem = name[:-2]
            return stem + "ия", stem + "ия", stem + "ию"
        if name.endswith("й"):           # Николай, Андрей, Матфей
            stem = name[:-1]
            return stem + "я", stem + "я", stem + "ю"
        if name.endswith("ия"):          # Илия, Захария
            stem = name[:-1]             # «Или», «Захари»
            return stem + "и", stem + "ю", stem + "и"
        if name.endswith("а"):           # Савва, Никита, Лука, Косма
            stem = name[:-1]
            gen = stem + ("и" if stem[-1] in HUSHING_OR_VELAR else "ы")
            return gen, stem + "у", stem + "е"
        if name.endswith("ь"):           # Игорь
            stem = name[:-1]
            return stem + "я", stem + "я", stem + "ю"
        if name[-1] not in VOWELS:       # согласный: Иоанн, Стефан
            return name + "а", name + "а", name + "у"
        raise ValueError(f"нет правила для мужского имени: {name}")

    # женские
    if name.endswith("ия"):              # Фотиния, Мария
        stem = name[:-1]
        return stem + "и", stem + "ю", stem + "и"
    if name.endswith("а"):               # Анна, Ольга, Марфа
        stem = name[:-1]
        gen = stem + ("и" if stem[-1] in HUSHING_OR_VELAR else "ы")
        return gen, stem + "у", stem + "е"
    if name.endswith("я"):               # Зоя
        stem = name[:-1]
        return stem + "и", stem + "ю", stem + "е"
    if name.endswith("ь"):               # Любовь (в OVERRIDES), Нинель
        stem = name[:-1]
        return stem + "и", name, stem + "и"
    raise ValueError(f"нет правила для женского имени: {name}")


def main() -> int:
    with open(JSON_PATH, encoding="utf-8") as f:
        data = json.load(f)

    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.executescript("""
        CREATE TABLE names (
            id         INTEGER PRIMARY KEY,
            input_form TEXT NOT NULL,
            canonical  TEXT NOT NULL,
            gender     TEXT NOT NULL,
            gen        TEXT NOT NULL,
            acc        TEXT NOT NULL,
            dat        TEXT,
            is_primary INTEGER NOT NULL DEFAULT 1,
            note       TEXT
        );
        CREATE INDEX idx_names_input ON names(input_form);
    """)

    declined: dict[str, tuple[str, str, str]] = {}
    rows = 0
    problems = []
    for entry in data["names"]:
        canonical = entry["canonical"]
        gender = entry["gender"]
        key = f"{canonical}|{gender}"
        if key not in declined:
            try:
                declined[key] = decline(canonical, gender)
            except ValueError as e:
                problems.append(str(e))
                continue
        gen, acc, dat = declined[key]
        is_primary = 0 if entry.get("primary") is False else 1
        note = entry.get("note")
        for form in entry["inputs"]:
            form_norm = form.strip().lower().replace("ё", "е")
            cur.execute(
                "INSERT INTO names (input_form, canonical, gender, gen, acc, dat, is_primary, note) "
                "VALUES (?,?,?,?,?,?,?,?)",
                (form_norm, canonical, gender, gen, acc, dat, is_primary, note))
            rows += 1

    conn.commit()

    print(f"Built {DB_PATH}: {rows} input forms, {len(declined)} склонённых имён\n")
    print("Проверьте формы (им. → род. / вин. / дат.):")
    for key in sorted(declined):
        canonical, gender = key.split("|")
        gen, acc, dat = declined[key]
        print(f"  {'м' if gender == 'm' else 'ж'} {canonical} → {gen} / {acc} / {dat}")

    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print("  !", p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
