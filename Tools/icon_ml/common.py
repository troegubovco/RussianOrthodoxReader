"""Shared paths, name utilities and image loading for the icon ML pipeline.

Every script in Tools/icon_ml imports from here so that paths and label
conventions stay consistent across the whole pipeline.
"""
from __future__ import annotations

import csv
import json
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path

# --- Repository layout -------------------------------------------------------

ICON_ML_DIR = Path(__file__).resolve().parent            # Tools/icon_ml
TOOLS_DIR = ICON_ML_DIR.parent                           # Tools
REPO_DIR = TOOLS_DIR.parent                              # repo root
DATA_DIR = TOOLS_DIR / "data"

DETAILS_JSON = DATA_DIR / "pravicon_details.json"
IMAGES_DIR = DATA_DIR / "pravicon_images" / "full"       # full/<category>/<image_id>.jpg
ICONS_DB = REPO_DIR / "RussianOrthodoxReader" / "Resources" / "Icons" / "icons.sqlite"

WORK_DIR = ICON_ML_DIR / "work"
CACHE_DIR = WORK_DIR / "cache512"                        # resized copies for fast training
MANIFEST_CSV = WORK_DIR / "manifest.csv"
MANIFEST_DEDUP_CSV = WORK_DIR / "manifest_dedup.csv"
SPLITS_DIR = WORK_DIR / "splits"
LABELS_JSON = WORK_DIR / "labels.json"
RUNS_DIR = WORK_DIR / "runs"
EXPORT_DIR = WORK_DIR / "export"
INDEX_DIR = WORK_DIR / "index"
AZBYKA_MATCH_CSV = WORK_DIR / "azbyka_match.csv"
AZBYKA_CONTENT_JSON = WORK_DIR / "azbyka_content.json"
META_DB = WORK_DIR / "icon_meta.sqlite"

# Subjects that are catch-all galleries on pravicon.com, not identifiable
# iconographic subjects. They are excluded from training classes but reused
# as out-of-distribution (OOD) samples for open-set threshold calibration.
BLACKLIST_RE = re.compile(r"Разное|фотографии христианских реликвий", re.IGNORECASE)

MANIFEST_FIELDS = ["image_id", "icon_id", "category", "name", "relpath", "ambiguous"]

# --- Name handling ------------------------------------------------------------

# Rank abbreviations pravicon appends after a comma ("Сергий Радонежский, прп.").
_RANK_RE = re.compile(
    r"^(свт|прп|прпп|мч|мц|мчч|мцц|вмч|вмц|сщмч|сщисп|прмч|прмц|блгв|блж|прав|"
    r"равноап|бесср|исп|ап|апп|прор|прорnever|св|свв)\.?$",
    re.IGNORECASE,
)


def base_name(pravicon_name: str) -> str:
    """'Сергий Радонежский, прп.' -> 'Сергий Радонежский' (rank stripped)."""
    name = pravicon_name.strip()
    parts = [p.strip() for p in name.split(",")]
    while len(parts) > 1 and _RANK_RE.match(parts[-1]):
        parts.pop()
    return ", ".join(parts).strip()


def paren_variants(name: str) -> list[str]:
    """Return the name plus alternatives from parentheses.

    'Спас Вседержитель (Господь Вседержитель, Пантократор)' ->
    ['Спас Вседержитель', 'Господь Вседержитель', 'Пантократор']
    """
    m = re.match(r"^(.*?)\s*\((.*?)\)\s*$", name)
    if not m:
        return [name]
    variants = [m.group(1).strip()]
    variants += [v.strip() for v in m.group(2).split(",") if v.strip()]
    return [v for v in variants if v]


_TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "j", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "ju", "я": "ja",
}


def translit_slug(text: str) -> str:
    """Transliterate Russian text to an azbyka.ru-style URL slug."""
    text = unicodedata.normalize("NFC", text).lower()
    out = []
    for ch in text:
        if ch in _TRANSLIT:
            out.append(_TRANSLIT[ch])
        elif ch.isascii() and (ch.isalnum()):
            out.append(ch)
        else:
            out.append("-")
    slug = re.sub(r"-+", "-", "".join(out)).strip("-")
    return slug


# --- Manifest I/O --------------------------------------------------------------

@dataclass
class ManifestRow:
    image_id: int
    icon_id: int
    category: str
    name: str
    relpath: str          # relative to Tools/data/pravicon_images
    ambiguous: int        # 1 if the image belongs to more than one subject


def read_manifest(path: Path) -> list[ManifestRow]:
    rows: list[ManifestRow] = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows.append(ManifestRow(
                image_id=int(r["image_id"]),
                icon_id=int(r["icon_id"]),
                category=r["category"],
                name=r["name"],
                relpath=r["relpath"],
                ambiguous=int(r["ambiguous"]),
            ))
    return rows


def write_manifest(path: Path, rows: list[ManifestRow]):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(MANIFEST_FIELDS)
        for r in rows:
            w.writerow([r.image_id, r.icon_id, r.category, r.name, r.relpath, r.ambiguous])


def resolve_image_path(relpath: str) -> Path:
    """Prefer the resized cache copy (work/cache512) when it exists.

    `relpath` looks like 'full/saints/12345.jpg'; the cache mirrors it as
    'saints/12345.jpg'.
    """
    cache_rel = relpath[len("full/"):] if relpath.startswith("full/") else relpath
    cached = CACHE_DIR / cache_rel
    if cached.exists():
        return cached
    return DATA_DIR / "pravicon_images" / relpath


def load_labels(path: Path = LABELS_JSON) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return json.load(f)["classes"]
