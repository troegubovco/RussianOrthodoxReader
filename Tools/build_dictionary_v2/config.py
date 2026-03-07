"""
config.py — Pipeline configuration constants.
"""
from pathlib import Path

# ── Paths ────────────────────────────────────────────────────────────────────
ROOT = Path(__file__).parent
DATA_DIR = ROOT / "data"
BIBLE_DB = ROOT.parent.parent / "RussianOrthodoxReader" / "Resources" / "Bible" / "rus_synodal.sqlite"
OUTPUT_DB = ROOT.parent.parent / "RussianOrthodoxReader" / "Resources" / "Bible" / "rus_dictionary.sqlite"

# Intermediate files
PASS1_OUTPUT = DATA_DIR / "pass1_words.json"
PASS2_RESULTS = DATA_DIR / "pass2_results.jsonl"
PASS2_CHECKPOINT = DATA_DIR / "pass2_checkpoint.json"
PASS2_SUMMARY = DATA_DIR / "pass2_summary.json"
PASS3_RESULTS = DATA_DIR / "pass3_definitions.jsonl"
PASS3_CHECKPOINT = DATA_DIR / "pass3_checkpoint.json"

# ── YandexGPT API (OpenAI-compatible) ────────────────────────────────────────
# Auth: export YANDEX_API_KEY='your-api-key'
YANDEX_BASE_URL = "https://ai.api.cloud.yandex.net/v1"
YANDEX_FOLDER_ID = "b1g41tvg6vthj5m2qfp9"
YANDEX_MODEL = "yandexgpt/latest"   # YandexGPT 5 Pro
YANDEX_TIMEOUT = 120                 # seconds per API call
YANDEX_MAX_RETRIES = 5
YANDEX_RETRY_BASE_DELAY = 2.0       # seconds, doubles each retry
YANDEX_DELAY_BETWEEN_CALLS = 0.5    # seconds between calls (rate limiting)
YANDEX_MAX_TOKENS = 8000            # max output tokens per call

def yandex_model_uri() -> str:
    """Build the full model URI for YandexGPT Responses API."""
    return f"gpt://{YANDEX_FOLDER_ID}/{YANDEX_MODEL}"

# ── Pass 1 — Word extraction ────────────────────────────────────────────────
MIN_WORD_LENGTH = 2          # Skip single-character tokens
MAX_REFS_PER_WORD = 5        # Max verse references to store per word

# ── Pass 2 — Lemmatization + classification ──────────────────────────────────
PASS2_BATCH_SIZE = 30        # Words per API call (smaller = better accuracy with YandexGPT)
PASS2_TEMPERATURE = 0.2      # Low temp for consistent classification

# ── Pass 3 — Definition generation ───────────────────────────────────────────
PASS3_BATCH_SIZE = 10        # Lemmas per API call (smaller = better quality with YandexGPT)
PASS3_TEMPERATURE = 0.4      # Slightly higher for natural definitions
PASS3_MAX_VERSES_PER_WORD = 3  # Example verses per word in prompt

# ── Pass 4 — SQLite build ───────────────────────────────────────────────────
DICT_SOURCE = "Библейский словарь"
